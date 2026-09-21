#!/usr/bin/env julia
# Render the files the site reads (data/*.json.gz, data/benchmarks/*.json.gz,
# data/agents/*) from the database, in the shapes the fetchers write today.
#
#   julia --project db/export.jl --out DIR [--db PATH] [--only timing,benchmarks,...]
#
# Files are written to a temporary name and renamed into place, so a reader
# never sees a partial file. db/compare.jl checks an export against data/.

using Pkg
Pkg.activate(dirname(@__DIR__); io=devnull)

include(joinpath(@__DIR__, "Store.jl"))
using .Store
using SQLite, DBInterface, JSON3, CodecZlib, DataStructures, Dates, Statistics

const SOURCES = ["timing", "benchmarks", "pkgeval", "ttfx", "packages", "agents"]

function parse_args(args)
    opts = Dict{String,Any}("db" => Store.DEFAULT_PATH, "out" => nothing, "only" => SOURCES)
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--db"
            opts["db"] = args[i+1]; i += 2
        elseif a == "--out"
            opts["out"] = args[i+1]; i += 2
        elseif a == "--only"
            opts["only"] = split(args[i+1], ','); i += 2
        else
            error("unknown argument $a")
        end
    end
    opts["out"] === nothing && error("--out DIR is required")
    return opts
end

rows(db, sql, params=()) = SQLite.Tables.rowtable(DBInterface.execute(db, sql, params))

# SQL NULL comes back as `missing`; the files use null (or "" where the
# fetcher wrote strings).
js(x) = x === missing ? nothing : x
jstr(x) = x === missing ? "" : String(x)

function generated_at(db, source)
    r = rows(db, "SELECT finished_at FROM source_runs WHERE source = ? AND ok = 1 ORDER BY id DESC LIMIT 1", (source,))
    return isempty(r) ? Store.iso_now() : String(r[1].finished_at)
end

function write_atomic(f, path)
    mkpath(dirname(path))
    tmp = path * ".tmp"
    open(f, tmp, "w")
    mv(tmp, path; force=true)
end

write_gz_json(path, value) = write_atomic(path) do io
    write(io, transcode(GzipCompressor, Vector{UInt8}(JSON3.write(value))))
end

# --- timing ----------------------------------------------------------------

function export_timing(db, out)
    jobs = SortedDict{String,Any}()
    # Legacy order: date descending, then retry ascending. Number descending
    # settles ties within a pipeline the way the fetcher's merge did; ties
    # across pipelines in the same minute were fetch-order accidents.
    q = rows(db, """
        SELECT j.name, j.retry, j.agent_hostname, j.state, j.duration_s,
               b.pipeline, b.number, b.commit_prefix, b.author, b.message, b.created_at
        FROM jobs j JOIN builds b ON b.id = j.build_id
        ORDER BY j.name, b.created_at DESC, j.retry ASC, b.number DESC""")
    current = nothing
    recent = Any[]
    durations = Float64[]
    function flush!()
        current === nothing && return
        n = length(durations)
        jobs[current] = SortedDict(
            "recent" => copy(recent),
            "stats" => SortedDict(
                "count" => n,
                "max_seconds" => round(maximum(durations); digits=1),
                "mean_seconds" => round(mean(durations); digits=1),
                "median_seconds" => round(median(durations); digits=1),
                "min_seconds" => round(minimum(durations); digits=1),
                "std_seconds" => round(n > 1 ? std(durations) : 0.0; digits=1)))
    end
    for r in q
        name = String(r.name)
        if name != current
            flush!()
            current = name
            empty!(recent); empty!(durations)
        end
        push!(recent, SortedDict(
            "agent" => String(r.agent_hostname), "author" => String(r.author), "build" => Int(r.number),
            "commit" => String(r.commit_prefix), "date" => iso_to_legacy_minute(String(r.created_at)),
            "duration" => Float64(r.duration_s), "message" => String(r.message), "pipeline" => String(r.pipeline),
            "retry" => Int(r.retry), "state" => String(r.state)))
        push!(durations, Float64(r.duration_s))
    end
    flush!()
    coverage = SortedDict{String,Any}()
    for r in rows(db, "SELECT commit_sha, measured_at, codecov, coveralls FROM coverage")
        coverage[String(r.commit_sha)] = SortedDict("coveralls" => js(r.coveralls), "codecov" => js(r.codecov), "date" => js(r.measured_at))
    end
    summary = SortedDict("coverage" => coverage, "generated_at" => generated_at(db, "timing"), "jobs" => jobs)
    write_gz_json(joinpath(out, "timing_summary.json.gz"), summary)
    @info "timing" jobs=length(jobs)
end

# --- benchmarks --------------------------------------------------------------

function export_benchmarks(db, out)
    reports = rows(db, "SELECT id, date, path, commit_sha, baseline_date, report_total, report_regressions, report_improvements " *
                       "FROM bench_reports WHERE kind = 'daily' ORDER BY date")
    groups = rows(db, "SELECT report_id, grp, stat, geomean_ns, count FROM bench_report_groups")
    by_report = Dict{Int,Dict{String,Dict{String,Any}}}()
    for g in groups
        d = get!(by_report, Int(g.report_id), Dict{String,Dict{String,Any}}())
        e = get!(d, String(g.grp), Dict{String,Any}())
        e["$(g.stat)_geomean_ns"] = Float64(g.geomean_ns)
        e["$(g.stat)_count"] = Int(g.count)
    end
    summary_reports = Any[]
    for r in reports
        e = OrderedDict{String,Any}("date" => String(r.date), "date_path" => replace(String(r.path), "by_date/" => ""),
                                    "commit" => String(r.commit_sha), "by_group" => get(by_report, Int(r.id), Dict()))
        r.report_total === missing || (e["report_total"] = Int(r.report_total))
        r.report_regressions === missing || (e["report_regressions"] = Int(r.report_regressions))
        r.report_improvements === missing || (e["report_improvements"] = Int(r.report_improvements))
        r.baseline_date === missing || (e["report_baseline_date"] = String(r.baseline_date))
        push!(summary_reports, e)
    end
    write_gz_json(joinpath(out, "benchmark_summary.json.gz"),
                  OrderedDict("generated_at" => generated_at(db, "benchmarks"), "reports" => summary_reports))
    # Detail files: the dates of a (group, stat) are the reports with a
    # summary row for it; every benchmark name of the group gets a series.
    report_info = Dict(Int(r.id) => (String(r.date), replace(String(r.path), "by_date/" => ""), String(r.commit_sha)) for r in reports)
    present = Dict{Tuple{String,String},Vector{Int}}()
    for g in groups
        push!(get!(present, (String(g.grp), String(g.stat)), Int[]), Int(g.report_id))
    end
    names = rows(db, "SELECT id, grp, name FROM bench_names ORDER BY grp, name")
    grp_names = Dict{String,Vector{Tuple{Int,String}}}()
    for n in names
        push!(get!(grp_names, String(n.grp), Tuple{Int,String}[]), (Int(n.id), String(n.name)))
    end
    for grp in sort(collect(keys(grp_names)))
        detail = Dict{String,Any}()
        for stat in ("minimum", "mean")
            ids = sort(get(present, (grp, stat), Int[]); by=id -> report_info[id][1])
            pos = Dict(id => i for (i, id) in enumerate(ids))
            series = Dict{String,Vector{Union{Nothing,Float64}}}()
            bench_by_id = Dict{Int,Vector{Union{Nothing,Float64}}}()
            for (bid, bname) in grp_names[grp]
                v = Vector{Union{Nothing,Float64}}(nothing, length(ids))
                series[bname] = v
                bench_by_id[bid] = v
            end
            for r in DBInterface.execute(db, "SELECT r.report_id, r.bench_id, r.time_ns FROM bench_results r " *
                                             "JOIN bench_names n ON n.id = r.bench_id WHERE n.grp = ? AND r.stat = ?", (grp, stat))
                i = get(pos, Int(r.report_id), nothing)
                i === nothing && continue
                bench_by_id[Int(r.bench_id)][i] = Float64(r.time_ns)
            end
            detail[stat] = Dict("benchmarks" => series,
                                "dates" => [report_info[id][1] for id in ids],
                                "date_paths" => [report_info[id][2] for id in ids],
                                "commits" => [report_info[id][3] for id in ids])
        end
        write_gz_json(joinpath(out, "benchmarks", "$grp.json.gz"), detail)
    end
    @info "benchmarks" reports=length(reports) groups=length(grp_names)
end

# --- pkgeval -----------------------------------------------------------------

function export_pkgeval(db, out)
    reports = Any[]
    for r in rows(db, "SELECT date, path, commit_sha, julia_version, total, ok, fail, crash, skip, kill " *
                      "FROM pkgeval_reports WHERE kind = 'daily' ORDER BY date")
        push!(reports, OrderedDict("date" => String(r.date), "date_path" => replace(String(r.path), "by_date/" => ""),
                                   "total" => Int(r.total), "ok" => Int(r.ok), "fail" => Int(r.fail), "crash" => Int(r.crash),
                                   "skip" => Int(r.skip), "kill" => Int(r.kill), "version" => String(r.julia_version),
                                   "commit" => String(r.commit_sha)))
    end
    write_gz_json(joinpath(out, "pkgeval_summary.json.gz"),
                  OrderedDict("generated_at" => generated_at(db, "pkgeval"), "reports" => reports))
    @info "pkgeval" reports=length(reports)
end

# --- ttfx --------------------------------------------------------------------

const TTFX_METRICS = ["precompile", "load", "run", "warm", "load_gcoff", "run_gcoff", "warm_gcoff"]

function export_ttfx(db, out)
    results = Dict{String,Dict{String,Any}}()
    for r in rows(db, "SELECT job_uuid, task, precompile, load, run, warm, load_gcoff, run_gcoff, warm_gcoff FROM ttfx_results")
        vals = Any[js(getproperty(r, Symbol(m))) for m in TTFX_METRICS]
        get!(results, String(r.job_uuid), Dict{String,Any}())[String(r.task)] = vals
    end
    failures = Dict{String,Dict{String,String}}()
    for r in rows(db, "SELECT job_uuid, task, error FROM ttfx_failures")
        get!(failures, String(r.job_uuid), Dict{String,String}())[String(r.task)] = String(r.error)
    end
    builds = Any[]
    pipeline = "julia-ci"
    for j in rows(db, "SELECT * FROM ttfx_jobs ORDER BY build_created_at, build")
        pipeline = String(j.pipeline)
        tasks = get(results, String(j.job_uuid), Dict{String,Any}())
        n = Int(j.n_metrics)
        push!(builds, Dict{String,Any}(
            "build" => Int(j.build), "job_id" => String(j.job_uuid), "triplet" => String(j.triplet), "state" => String(j.state),
            "date" => iso_to_legacy_minute(String(j.build_created_at)), "commit" => String(j.commit_sha),
            "version" => String(j.version), "message" => String(j.message), "agent" => String(j.agent), "cpu" => String(j.cpu),
            "snippets" => String(j.snippets), "blocks" => js(j.blocks), "n_tasks" => js(j.n_tasks),
            "tasks" => Dict(k => v[1:n] for (k, v) in tasks),
            "failed" => get(failures, String(j.job_uuid), Dict{String,String}())))
    end
    task_names = sort!(unique(String[k for b in builds for d in (b["tasks"], b["failed"]) for k in keys(d)]))
    summary = OrderedDict("generated_at" => generated_at(db, "ttfx"), "pipeline" => pipeline, "branch" => "master",
                          "metrics" => TTFX_METRICS, "tasks" => task_names, "builds" => builds)
    write_gz_json(joinpath(out, "ttfx_summary.json.gz"), summary)
    @info "ttfx" jobs=length(builds)
end

# --- packages ----------------------------------------------------------------

const DL_SOURCE = "https://julialang-logs.s3.amazonaws.com/public_outputs/current/resource_types_by_date.csv.gz"
const DL_VERSIONS_SOURCE = "https://julialang-logs.s3.amazonaws.com/public_outputs/current/julia_versions_by_date.csv.gz"
const DL_TAGS_SOURCE = "https://api.github.com/repos/JuliaLang/julia/releases"

function export_packages(db, out)
    series = [OrderedDict("date" => String(r.date), "all" => Int(r.total_requests), "user" => Int(r.user_requests), "ci" => Int(r.ci_requests))
              for r in rows(db, "SELECT date, total_requests, user_requests, ci_requests FROM dl_series ORDER BY date")]
    counts(r) = OrderedDict("all" => Int(r.total_requests), "user" => Int(r.user_requests), "ci" => Int(r.ci_requests))
    function mix(kind, member)
        per_date = OrderedDict{String,Any}()
        for r in rows(db, "SELECT date, key, total_requests, user_requests, ci_requests FROM dl_mix WHERE kind = ? ORDER BY date, key", (kind,))
            e = get!(per_date, String(r.date)) do
                OrderedDict("date" => String(r.date), "totals" => nothing, member => OrderedDict{String,Any}())
            end
            if r.key == "*"
                e["totals"] = counts(r)
            else
                e[member][String(r.key)] = counts(r)
            end
        end
        return collect(values(per_date))
    end
    tag(r) = OrderedDict("tag" => String(r.tag), "date" => String(r.date), "published_at" => String(r.published_at), "url" => String(r.url))
    tags(pre) = [tag(r) for r in rows(db, "SELECT tag, date, published_at, url FROM julia_tags WHERE prerelease = ? ORDER BY date, published_at DESC", (pre,))]
    payload = OrderedDict(
        "generated_at" => generated_at(db, "packages"),
        "source" => DL_SOURCE,
        "julia_versions_source" => DL_VERSIONS_SOURCE,
        "julia_tags_source" => DL_TAGS_SOURCE,
        "julia_tags_window_years" => 2,
        "julia_tags" => tags(0),
        "julia_prerelease_tags" => tags(1),
        "maxDate" => isempty(series) ? nothing : series[end]["date"],
        "series" => series,
        "version_mix" => mix("version", "minors"),
        "version_stage_mix" => mix("stage", "channels"))
    write_gz_json(joinpath(out, "packages_downloads_summary.json.gz"), payload)
    @info "packages" days=length(series)
end

# --- agents ------------------------------------------------------------------

function export_agents(db, out)
    dir = joinpath(out, "agents")
    records = OrderedDict{String,Any}()
    for a in rows(db, "SELECT * FROM agents ORDER BY name")
        records[String(a.name)] = OrderedDict{String,Any}(
            "hostname" => String(a.hostname), "queue" => String(a.queue), "os" => String(a.os), "arch" => String(a.arch),
            "version" => String(a.version), "state" => String(a.state), "connected_at" => jstr(a.connected_at),
            "first_seen" => jstr(a.first_seen), "last_seen" => jstr(a.last_seen),
            "job" => a.job_json === missing ? nothing : JSON3.read(String(a.job_json), OrderedDict{String,Any}))
    end
    times = [String(r.time) for r in rows(db, "SELECT time FROM agent_snapshots ORDER BY time")]
    gen = isempty(times) ? generated_at(db, "agents") : times[end]
    latest = OrderedDict{String,Any}("generated_at" => gen, "agents" => records)
    write_atomic(joinpath(dir, "latest.json")) do io
        JSON3.pretty(io, JSON3.write(latest), JSON3.AlignmentContext(indent=1))
        println(io)
    end
    members = Dict{String,Vector{String}}()
    for r in rows(db, "SELECT time, agent_name FROM agent_snapshot_members ORDER BY time, agent_name")
        push!(get!(members, String(r.time), String[]), String(r.agent_name))
    end
    by_month = OrderedDict{String,Vector{String}}()
    for t in times
        push!(get!(by_month, t[1:7], String[]), t)
    end
    for (month, ts) in by_month
        write_atomic(joinpath(dir, "history-$month.ndjson")) do io
            for t in ts
                JSON3.write(io, OrderedDict("time" => t, "connected" => get(members, t, String[])))
                println(io)
            end
        end
    end
    @info "agents" agents=length(records) snapshots=length(times) months=length(by_month)
end

const EXPORTERS = Dict("timing" => export_timing, "benchmarks" => export_benchmarks, "pkgeval" => export_pkgeval,
                       "ttfx" => export_ttfx, "packages" => export_packages, "agents" => export_agents)

function main(args)
    opts = parse_args(args)
    db = open_db(opts["db"]; create=false)
    mkpath(opts["out"])
    for source in opts["only"]
        t = @elapsed EXPORTERS[String(source)](db, opts["out"])
        @info "exported $source" seconds=round(t; digits=1)
    end
    close(db)
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
