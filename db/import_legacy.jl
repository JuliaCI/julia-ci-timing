#!/usr/bin/env julia
# Populate the database from the committed data/ files. This is the history
# backfill: for timing it is the only copy there is (Buildkite only retains a
# window), for the rest it is cheaper than re-fetching years of reports.
#
#   julia --project db/import_legacy.jl [--db PATH] [--data DIR] [--only timing,benchmarks,...]
#
# Re-running is safe: every write is an upsert keyed the way the fetchers key
# their records, and unchanged rows are left alone. db/export.jl must
# reproduce the input files from the result; db/compare.jl checks that.

using Pkg
Pkg.activate(dirname(@__DIR__); io=devnull)

include(joinpath(@__DIR__, "Store.jl"))
using .Store
using SQLite, DBInterface, JSON3, CodecZlib, Dates

const SOURCES = ["timing", "benchmarks", "pkgeval", "ttfx", "packages", "agents"]

function parse_args(args)
    opts = Dict{String,Any}("db" => Store.DEFAULT_PATH,
                            "data" => joinpath(dirname(@__DIR__), "data"),
                            "only" => SOURCES)
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--db"
            opts["db"] = args[i+1]; i += 2
        elseif a == "--data"
            opts["data"] = args[i+1]; i += 2
        elseif a == "--only"
            opts["only"] = split(args[i+1], ','); i += 2
        else
            error("unknown argument $a")
        end
    end
    return opts
end

read_gz_json(path) = JSON3.read(transcode(GzipDecompressor, read(path)))
read_json(path) = JSON3.read(read(path))

# JSON3 gives `nothing` for null; the schema wants SQL NULL, which SQLite.jl
# binds from `missing`.
sql(x) = x === nothing ? missing : x
sqlstr(x) = x === nothing ? "" : String(x)

# Record the file's generated_at as a completed run so an export straight
# after the import carries the same timestamp.
function record_legacy_run!(db, source, generated_at, rows)
    ts = generated_at === nothing ? Store.iso_now() : String(generated_at)
    DBInterface.execute(db, "INSERT INTO source_runs (source, started_at, finished_at, ok, rows_written) VALUES (?, ?, ?, 1, ?)",
                        (source, ts, ts, rows))
end

# --- timing ----------------------------------------------------------------

function import_timing!(db, data_dir)
    path = joinpath(data_dir, "timing_summary.json.gz")
    isfile(path) || (@warn "missing $path"; return)
    summary = read_gz_json(path)
    seq = next_seq!(db)
    build_stmt = upsert_stmt(db, "builds", ["pipeline", "number"], ["commit_prefix", "author", "message", "created_at"])
    job_stmt = upsert_stmt(db, "jobs", ["build_id", "name", "retry"], ["agent_hostname", "state", "duration_s"])
    cov_stmt = upsert_stmt(db, "coverage", ["commit_sha"], ["measured_at", "codecov", "coveralls"])
    build_ids = Dict{Tuple{String,Int},Int}()
    build_meta = Dict{Tuple{String,Int},NTuple{4,String}}()
    conflicts = 0
    njobs = 0
    for (name, job) in pairs(summary.jobs)
        for r in job.recent
            key = (String(r.pipeline), Int(r.build))
            meta = (String(r.commit), sqlstr(r.author), sqlstr(r.message), legacy_minute_to_iso(String(r.date)))
            id = get(build_ids, key, nothing)
            if id === nothing
                upsert!(build_stmt, (key[1], key[2], meta..., seq))
                id = Int(query(db, "SELECT id FROM builds WHERE pipeline = ? AND number = ?", key)[1].id)
                build_ids[key] = id
                build_meta[key] = meta
            elseif build_meta[key] != meta
                # Jobs of one build disagreeing on its commit/author/message/date
                conflicts += 1
            end
            upsert!(job_stmt, (id, String(name), Int(get(r, :retry, 0)), sqlstr(r.agent), sqlstr(r.state), Float64(r.duration), seq))
            njobs += 1
        end
    end
    conflicts > 0 && @warn "build metadata conflicts between jobs of the same build" conflicts
    ncov = 0
    for (sha, c) in pairs(get(summary, :coverage, Dict()))
        upsert!(cov_stmt, (String(sha), sql(get(c, :date, nothing)), sql(get(c, :codecov, nothing)), sql(get(c, :coveralls, nothing)), seq))
        ncov += 1
    end
    record_legacy_run!(db, "timing", get(summary, :generated_at, nothing), njobs)
    @info "timing" builds=length(build_ids) jobs=njobs coverage=ncov
end

# --- benchmarks --------------------------------------------------------------

function import_benchmarks!(db, data_dir)
    path = joinpath(data_dir, "benchmark_summary.json.gz")
    isfile(path) || (@warn "missing $path"; return)
    summary = read_gz_json(path)
    seq = next_seq!(db)
    report_stmt = upsert_stmt(db, "bench_reports", ["path"],
        ["kind", "date", "commit_sha", "baseline_date", "report_total", "report_regressions", "report_improvements"])
    group_stmt = upsert_stmt(db, "bench_report_groups", ["report_id", "grp", "stat"], ["geomean_ns", "count"]; seq=false)
    report_ids = Dict{String,Int}()
    for r in summary.reports
        p = "by_date/" * String(r.date_path)
        upsert!(report_stmt, (p, "daily", String(r.date), sqlstr(r.commit), sql(get(r, :report_baseline_date, nothing)),
                              sql(get(r, :report_total, nothing)), sql(get(r, :report_regressions, nothing)),
                              sql(get(r, :report_improvements, nothing)), seq))
        id = Int(query(db, "SELECT id FROM bench_reports WHERE path = ?", (p,))[1].id)
        report_ids[String(r.date)] = id
        for (grp, g) in pairs(r.by_group)
            for stat in ("minimum", "mean")
                gm = get(g, Symbol("$(stat)_geomean_ns"), nothing)
                cnt = get(g, Symbol("$(stat)_count"), nothing)
                gm === nothing && continue
                upsert!(group_stmt, (id, String(grp), stat, Float64(gm), Int(cnt)))
            end
        end
    end
    # Detail files: one row per non-null cell. A 0 is a value (kept), null is
    # absence (no row), so the export reproduces both.
    result_stmt = DBInterface.prepare(db,
        "INSERT INTO bench_results (report_id, bench_id, stat, time_ns) VALUES (?, ?, ?, ?) " *
        "ON CONFLICT (report_id, bench_id, stat) DO UPDATE SET time_ns = excluded.time_ns WHERE bench_results.time_ns IS NOT excluded.time_ns")
    names = Dict{Tuple,Int}()
    ncells = 0
    benchdir = joinpath(data_dir, "benchmarks")
    for f in sort(readdir(benchdir))
        endswith(f, ".json.gz") || continue
        grp = replace(f, ".json.gz" => "")
        detail = read_gz_json(joinpath(benchdir, f))
        for stat in ("minimum", "mean")
            blk = get(detail, Symbol(stat), nothing)
            blk === nothing && continue
            dates = blk.dates
            # The detail arrays must agree with the summary; checked on
            # 2026-09-21 and true for every group, so no extra columns.
            ids = [report_ids[String(d)] for d in dates]
            for (bname, series) in pairs(blk.benchmarks)
                bid = getid!(names, db, "bench_names", ("grp", "name"), (grp, String(bname)))
                for (i, v) in enumerate(series)
                    v === nothing && continue
                    DBInterface.execute(result_stmt, (ids[i], bid, stat, Float64(v)))
                    ncells += 1
                end
            end
        end
    end
    record_legacy_run!(db, "benchmarks", get(summary, :generated_at, nothing), ncells)
    @info "benchmarks" reports=length(report_ids) names=length(names) cells=ncells
end

# --- pkgeval -----------------------------------------------------------------

function import_pkgeval!(db, data_dir)
    path = joinpath(data_dir, "pkgeval_summary.json.gz")
    isfile(path) || (@warn "missing $path"; return)
    summary = read_gz_json(path)
    seq = next_seq!(db)
    stmt = upsert_stmt(db, "pkgeval_reports", ["path"],
        ["kind", "date", "commit_sha", "julia_version", "total", "ok", "fail", "crash", "skip", "kill"])
    n = 0
    for r in summary.reports
        upsert!(stmt, ("by_date/" * String(r.date_path), "daily", String(r.date), sqlstr(r.commit), sqlstr(r.version),
                       Int(r.total), Int(r.ok), Int(r.fail), Int(r.crash), Int(r.skip), Int(r.kill), seq))
        n += 1
    end
    record_legacy_run!(db, "pkgeval", get(summary, :generated_at, nothing), n)
    @info "pkgeval" reports=n
end

# --- ttfx --------------------------------------------------------------------

const TTFX_METRICS = ("precompile", "load", "run", "warm", "load_gcoff", "run_gcoff", "warm_gcoff")

function import_ttfx!(db, data_dir)
    path = joinpath(data_dir, "ttfx_summary.json.gz")
    isfile(path) || (@warn "missing $path"; return)
    summary = read_gz_json(path)
    seq = next_seq!(db)
    job_stmt = upsert_stmt(db, "ttfx_jobs", ["job_uuid"],
        ["pipeline", "build", "triplet", "state", "build_created_at", "commit_sha", "version", "message",
         "agent", "cpu", "snippets", "blocks", "n_tasks", "n_metrics"])
    res_stmt = upsert_stmt(db, "ttfx_results", ["job_uuid", "task"], collect(TTFX_METRICS); seq=false)
    fail_stmt = upsert_stmt(db, "ttfx_failures", ["job_uuid", "task"], ["error"]; seq=false)
    pipeline = sqlstr(get(summary, :pipeline, "julia-ci"))
    n = 0
    for b in summary.builds
        uuid = String(b.job_id)
        tasks = get(b, :tasks, Dict())
        failed = get(b, :failed, Dict())
        # Rows without task arrays (failed jobs) count as complete so the
        # fetcher's short-row rule does not re-fetch them forever.
        n_metrics = isempty(tasks) ? length(TTFX_METRICS) : maximum(length(v) for v in values(tasks))
        upsert!(job_stmt, (uuid, pipeline, Int(b.build), String(b.triplet), String(b.state),
                           legacy_minute_to_iso(String(b.date)), sqlstr(b.commit), sqlstr(get(b, :version, "")),
                           sqlstr(get(b, :message, "")), sqlstr(get(b, :agent, "")), sqlstr(get(b, :cpu, "")),
                           sqlstr(get(b, :snippets, "")), sql(get(b, :blocks, nothing)), sql(get(b, :n_tasks, nothing)),
                           n_metrics, seq))
        # Replace children wholesale, as the fetcher replaces the row
        DBInterface.execute(db, "DELETE FROM ttfx_results WHERE job_uuid = ?", (uuid,))
        DBInterface.execute(db, "DELETE FROM ttfx_failures WHERE job_uuid = ?", (uuid,))
        for (task, vals) in pairs(tasks)
            padded = [i <= length(vals) ? sql(vals[i]) : missing for i in 1:length(TTFX_METRICS)]
            upsert!(res_stmt, (uuid, String(task), padded...))
        end
        for (task, err) in pairs(failed)
            upsert!(fail_stmt, (uuid, String(task), String(err)))
        end
        n += 1
    end
    record_legacy_run!(db, "ttfx", get(summary, :generated_at, nothing), n)
    @info "ttfx" jobs=n
end

# --- packages ----------------------------------------------------------------

function import_packages!(db, data_dir)
    path = joinpath(data_dir, "packages_downloads_summary.json.gz")
    isfile(path) || (@warn "missing $path"; return)
    summary = read_gz_json(path)
    seq = next_seq!(db)
    series_stmt = upsert_stmt(db, "dl_series", ["date"], ["total_requests", "user_requests", "ci_requests"])
    mix_stmt = upsert_stmt(db, "dl_mix", ["date", "kind", "key"], ["total_requests", "user_requests", "ci_requests"]; seq=false)
    tag_stmt = upsert_stmt(db, "julia_tags", ["tag"], ["date", "published_at", "url", "prerelease"]; seq=false)
    n = 0
    for s in summary.series
        upsert!(series_stmt, (String(s.date), Int(s.all), Int(s.user), Int(s.ci), seq))
        n += 1
    end
    counts(c) = (Int(c.all), Int(c.user), Int(c.ci))
    for e in get(summary, :version_mix, [])
        upsert!(mix_stmt, (String(e.date), "version", "*", counts(e.totals)...))
        for (minor, c) in pairs(e.minors)
            upsert!(mix_stmt, (String(e.date), "version", String(minor), counts(c)...))
        end
    end
    for e in get(summary, :version_stage_mix, [])
        upsert!(mix_stmt, (String(e.date), "stage", "*", counts(e.totals)...))
        for (channel, c) in pairs(e.channels)
            upsert!(mix_stmt, (String(e.date), "stage", String(channel), counts(c)...))
        end
    end
    for (list, pre) in ((get(summary, :julia_tags, []), 0), (get(summary, :julia_prerelease_tags, []), 1))
        for t in list
            upsert!(tag_stmt, (String(t.tag), String(t.date), String(t.published_at), String(t.url), pre))
        end
    end
    record_legacy_run!(db, "packages", get(summary, :generated_at, nothing), n)
    @info "packages" days=n
end

# --- agents ------------------------------------------------------------------

fold_key(name) = replace(name, r"\.\d+$" => "")

function import_agents!(db, data_dir)
    dir = joinpath(data_dir, "agents")
    latest_path = joinpath(dir, "latest.json")
    isfile(latest_path) || (@warn "missing $latest_path"; return)
    latest = read_json(latest_path)
    seq = next_seq!(db)
    agent_stmt = upsert_stmt(db, "agents", ["name"],
        ["fold_key", "hostname", "queue", "os", "arch", "version", "state", "connected_at", "first_seen", "last_seen", "job_json"])
    n = 0
    for (name, a) in pairs(latest.agents)
        job = get(a, :job, nothing)
        upsert!(agent_stmt, (String(name), fold_key(String(name)), sqlstr(get(a, :hostname, "")), sqlstr(get(a, :queue, "")),
                             sqlstr(get(a, :os, "")), sqlstr(get(a, :arch, "")), sqlstr(get(a, :version, "")),
                             sqlstr(get(a, :state, "")), sql(get(a, :connected_at, nothing)), sql(get(a, :first_seen, nothing)),
                             sql(get(a, :last_seen, nothing)), job === nothing ? missing : JSON3.write(job), seq))
        n += 1
    end
    snap_stmt = DBInterface.prepare(db, "INSERT OR IGNORE INTO agent_snapshots (time) VALUES (?)")
    member_stmt = DBInterface.prepare(db, "INSERT OR IGNORE INTO agent_snapshot_members (time, agent_name) VALUES (?, ?)")
    nsnap = 0
    for f in sort(readdir(dir))
        m = match(r"^history-(\d{4}-\d{2})\.ndjson$", f)
        m === nothing && continue
        for line in eachline(joinpath(dir, f))
            isempty(strip(line)) && continue
            snap = JSON3.read(line)
            t = String(snap.time)
            DBInterface.execute(snap_stmt, (t,))
            for a in snap.connected
                DBInterface.execute(member_stmt, (t, String(a)))
            end
            nsnap += 1
        end
    end
    record_legacy_run!(db, "agents", get(latest, :generated_at, nothing), n)
    @info "agents" agents=n snapshots=nsnap
end

const IMPORTERS = Dict("timing" => import_timing!, "benchmarks" => import_benchmarks!, "pkgeval" => import_pkgeval!,
                       "ttfx" => import_ttfx!, "packages" => import_packages!, "agents" => import_agents!)

function main(args)
    opts = parse_args(args)
    db = open_db(opts["db"])
    for source in opts["only"]
        f = IMPORTERS[String(source)]
        t = @elapsed transaction(db) do
            f(db, opts["data"])
        end
        @info "imported $source" seconds=round(t; digits=1)
    end
    DBInterface.execute(db, "PRAGMA optimize")
    close(db)
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
