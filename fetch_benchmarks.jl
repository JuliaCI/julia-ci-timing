#!/usr/bin/env julia
# Fetch Julia Base benchmark reports from NanosoldierReports into the
# database (db/). Clones the repo (sparse checkout of benchmark/by_date) and
# reads each new report's data.tar.zst and report.md: every BenchmarkTools
# estimate (minimum, median, mean, std; time, gctime, memory, allocs), the
# per-group geomeans the site plots, Nanosoldier's own regression verdicts and
# the run environment. db/export.jl renders data/benchmark* from the result.

using JSON3
using Dates
using Statistics
using CodecZstd
using Tar

include(joinpath(@__DIR__, "db", "Store.jl"))
using .Store
using SQLite, DBInterface

const REPORTS_REPO = "https://github.com/JuliaCI/NanosoldierReports.git"
# Persistent on the ingest host; the update workflow caches it
const CLONE_DIR = joinpath(@__DIR__, ".cache", "NanosoldierReports-benchmark")

# Statistics read from every new report, and the two the legacy files hold
# (a report lacking one of those is parsed again; the others are backfilled
# separately with --backfill-stats, since it means reading every tarball).
const STATS = ("minimum", "median", "mean", "std")
const LEGACY_STATS = ("minimum", "mean")

function ensure_clone()
    by_date = joinpath(CLONE_DIR, "benchmark", "by_date")
    if isdir(joinpath(CLONE_DIR, ".git"))
        @info "Updating existing clone..." dir=CLONE_DIR
        run(`git -C $CLONE_DIR fetch --depth 1 origin`)
        run(`git -C $CLONE_DIR reset --hard origin/master`)
    else
        @info "Cloning NanosoldierReports (sparse)..." dir=CLONE_DIR
        rm(CLONE_DIR; force=true, recursive=true)
        mkpath(dirname(CLONE_DIR))
        run(`git clone --depth 1 --filter=blob:none --sparse $REPORTS_REPO $CLONE_DIR`)
        run(`git -C $CLONE_DIR sparse-checkout set benchmark/by_date`)
    end
    isdir(by_date) || error("benchmark/by_date not found after clone")
    return by_date
end

function enumerate_report_dates(by_date_dir::String)
    dates = String[]
    for month in readdir(by_date_dir; sort=true)
        month_path = joinpath(by_date_dir, month)
        isdir(month_path) || continue
        for day in readdir(month_path; sort=true)
            isdir(joinpath(month_path, day)) || continue
            push!(dates, "$month/$day")
        end
    end
    @info "Found $(length(dates)) benchmark reports"
    return dates
end

function date_path_to_date(path::String)
    parts = split(path, "/")
    "$(parts[1])-$(lpad(parts[2], 2, '0'))"
end

# --- report.md ---------------------------------------------------------------

"""
Everything the report markdown states about the run: the commit and the
baseline it was compared against, the summary counts, the environment from
`## Version Info`, and the per-benchmark verdict table. Each field is
`nothing` when absent.
"""
function parse_report_md(by_date_dir::String, date_path::String)
    report_file = joinpath(by_date_dir, date_path, "report.md")
    empty = (commit="", baseline_commit=nothing, baseline_date=nothing, total=nothing, regressions=nothing,
             improvements=nothing, julia_version=nothing, llvm=nothing, cpu=nothing, os=nothing,
             nanosoldier_commit=nothing, verdicts=NamedTuple[])
    isfile(report_file) || return empty
    text = read(report_file, String)
    cap(re) = (m = match(re, text); m === nothing ? nothing : String(m.captures[1]))
    m = match(r"\*\*(\d+)\*\* benchmarks were executed,\s*\*\*(\d+)\*\* showed\s*regressions,\s*and\s*\*\*(\d+)\*\* showed\s*improvements"s, text)
    counts = m === nothing ? (nothing, nothing, nothing) : Tuple(parse(Int, c) for c in m.captures)
    verdicts = NamedTuple[]
    for vm in eachmatch(r"^\| `(\[.*?\])` \| ([0-9.]+) \(([0-9.]+)%\)\s*(:x:|:white_check_mark:)? *\| ([0-9.]+) \(([0-9.]+)%\)\s*(:x:|:white_check_mark:)? *\|"m, text)
        id = parse_bench_id(vm.captures[1])
        id === nothing && continue
        flag = something(vm.captures[4], vm.captures[7], "")
        push!(verdicts, (grp=id[1], name=id[2], time_ratio=parse(Float64, vm.captures[2]), time_tolerance=parse(Float64, vm.captures[3]) / 100,
                         memory_ratio=parse(Float64, vm.captures[5]), memory_tolerance=parse(Float64, vm.captures[6]) / 100,
                         verdict=flag == ":x:" ? "regression" : flag == ":white_check_mark:" ? "improvement" : "invariant"))
    end
    return (commit=something(cap(r"JuliaLang/julia@([0-9a-f]+)"), ""),
            baseline_commit=cap(r"/compare/([0-9a-f]{40})\.\.\.[0-9a-f]{40}"),
            baseline_date=cap(r"Daily Job:\*\s*\d{4}-\d{2}-\d{2}\s*vs\s*\[(\d{4}-\d{2}-\d{2})\]"),
            total=counts[1], regressions=counts[2], improvements=counts[3],
            julia_version=cap(r"^Julia Version (\S+)"m), llvm=cap(r"^\s*LLVM: (\S+)"m),
            cpu=cap(r"^\s*CPU: (.+?):?\s*$"m), os=cap(r"^\s*OS: (.+?)\s*$"m),
            nanosoldier_commit=cap(r"Nanosoldier commit: \[`([0-9a-f]+)`\]"),
            verdicts=verdicts)
end

# `["array", "setindex!", ("setindex!", 1)]` -> ("array", "setindex!/('setindex!', 1)"),
# the key form walk_estimates! produces from the JSON.
function parse_bench_id(id::AbstractString)
    inner = strip(id)[2:end-1]
    parts = String[]
    buf = IOBuffer(); depth = 0; inq = false
    for c in inner
        if c == '"'
            inq = !inq
        elseif !inq && c == '('
            depth += 1
        elseif !inq && c == ')'
            depth -= 1
        end
        if c == ',' && depth == 0 && !inq
            push!(parts, strip(String(take!(buf))))
        else
            write(buf, c)
        end
    end
    push!(parts, strip(String(take!(buf))))
    length(parts) >= 2 || return nothing
    unquote(p) = startswith(p, '"') && endswith(p, '"') ? p[2:end-1] : p
    grp = unquote(parts[1])
    name = join((replace(unquote(p), '"' => '\'') for p in parts[2:end]), "/")
    return (grp, name)
end

# --- data.tar.zst ------------------------------------------------------------

# Walk a BenchmarkTools JSON structure ([metadata, [["BenchmarkGroup", {"data": ...}]]])
# and collect every TrialEstimate per top-level group:
# group => benchmark path => (time, gctime, memory, allocs)
function collect_group_estimates(parsed)
    result = Dict{String,Dict{String,NTuple{4,Float64}}}()
    data_root = parsed[2][1][2]["data"]
    for (group_name, group_node) in data_root
        benchmarks = Dict{String,NTuple{4,Float64}}()
        walk_estimates!(benchmarks, group_node, String[])
        isempty(benchmarks) || (result[String(group_name)] = benchmarks)
    end
    return result
end

function walk_estimates!(benchmarks, node, path::Vector{String})
    node isa AbstractVector && length(node) == 2 || return
    tag = node[1]
    tag isa AbstractString || return
    if tag == "TrialEstimate"
        t = get(node[2], "time", nothing)
        t === nothing && return
        num(k) = (v = get(node[2], k, nothing); v === nothing ? NaN : Float64(v))
        benchmarks[join(path, "/")] = (Float64(t), num("gctime"), num("memory"), num("allocs"))
    elseif tag == "BenchmarkGroup"
        for (name, child) in get(node[2], "data", Dict())
            walk_estimates!(benchmarks, child, [path; replace(String(name), '"' => '\'')])
        end
    end
end

geomean(xs) = isempty(xs) ? 0.0 : exp(mean(log, xs))

"""
    parse_tarball(by_date_dir, date_path, stats) -> Dict(stat => group => bench => estimate), errors

The estimates of the requested statistics, plus the `errors.json` list.
`nothing` when there is no tarball or it cannot be read.
"""
function parse_tarball(by_date_dir::String, date_path::String, stats)
    tarball = joinpath(by_date_dir, date_path, "data.tar.zst")
    isfile(tarball) || return nothing
    tmpdir = mktempdir()
    try
        open(tarball) do io
            stream = ZstdDecompressorStream(io)
            Tar.extract(stream, tmpdir)
            close(stream)
        end
        by_stat = Dict{String,Any}()
        for stat in stats
            files = filter(f -> endswith(f, "_primary.$stat.json"), readdir(tmpdir))
            isempty(files) && continue
            parsed = try
                JSON3.read(read(joinpath(tmpdir, files[1]), String); allow_inf=true)
            catch e
                @warn "Failed to parse JSON" date_path stat error=e
                continue
            end
            by_stat[stat] = collect_group_estimates(parsed)
        end
        errors = Any[]
        efile = filter(f -> endswith(f, "_primary.errors.json"), readdir(tmpdir))
        if !isempty(efile)
            errors = try
                collect(JSON3.read(read(joinpath(tmpdir, efile[1]), String)))
            catch e
                @warn "Failed to parse errors.json" date_path error=e
                Any[]
            end
        end
        return by_stat, errors
    catch e
        @warn "Failed to extract tarball" date_path error=e
        return nothing
    finally
        rm(tmpdir; recursive=true, force=true)
    end
end

# --- database ------------------------------------------------------------------

const REPORT_COLS = ["kind", "date", "commit_sha", "baseline_commit_sha", "baseline_date", "julia_version", "llvm", "cpu", "os",
                     "nanosoldier_commit", "report_total", "report_regressions", "report_improvements"]

sql(x) = x === nothing ? missing : x
nan_missing(x) = isnan(x) ? missing : x

function report_id(db, path)
    r = query(db, "SELECT id FROM bench_reports WHERE path = ?", (path,))
    return isempty(r) ? nothing : Int(r[1].id)
end

# Write one report: its header row from report.md, then for every parsed
# statistic the per-group summary and the per-benchmark estimates. Existing
# rows for a re-parsed statistic are replaced, others left alone.
function write_report!(db, date_path, md, parsed, names, seq)
    path = "by_date/" * date_path
    rstmt = upsert_stmt(db, "bench_reports", ["path"], REPORT_COLS)
    upsert!(rstmt, (path, "daily", date_path_to_date(date_path), md.commit, sql(md.baseline_commit), sql(md.baseline_date),
                    sql(md.julia_version), sql(md.llvm), sql(md.cpu), sql(md.os), sql(md.nanosoldier_commit),
                    sql(md.total), sql(md.regressions), sql(md.improvements), seq))
    id = report_id(db, path)
    parsed === nothing && return 0
    by_stat, errors = parsed
    gstmt = upsert_stmt(db, "bench_report_groups", ["report_id", "grp", "stat"],
                        ["geomean_ns", "count", "gctime_geomean_ns", "gctime_count", "memory_geomean_bytes", "memory_count",
                         "allocs_geomean", "allocs_count"]; seq=false)
    estmt = upsert_stmt(db, "bench_results", ["report_id", "bench_id", "stat"], ["time_ns", "gctime_ns", "memory_bytes", "allocs"]; seq=false)
    n = 0
    for (stat, groups) in by_stat
        for (grp, benches) in groups
            times = [e[1] for e in values(benches)]
            # The other estimates' geomeans over the benchmarks with a positive value
            positive(i) = Float64[e[i] for e in values(benches) if !isnan(e[i]) && e[i] > 0]
            gc, mem, al = positive(2), positive(3), positive(4)
            upsert!(gstmt, (id, grp, stat, geomean(times), length(times), geomean(gc), length(gc), geomean(mem), length(mem),
                            geomean(al), length(al)))
            for (name, e) in benches
                bid = getid!(names, db, "bench_names", ("grp", "name"), (grp, name))
                upsert!(estmt, (id, bid, stat, e[1], nan_missing(e[2]), nan_missing(e[3]) === missing ? missing : Int(e[3]),
                                nan_missing(e[4]) === missing ? missing : Int(e[4])))
                n += 1
            end
        end
    end
    vstmt = upsert_stmt(db, "bench_verdicts", ["report_id", "bench_id"],
                        ["time_ratio", "time_tolerance", "memory_ratio", "memory_tolerance", "verdict"]; seq=false)
    unmatched = 0
    for v in md.verdicts
        bid = get(names, (v.grp, v.name), nothing)
        if bid === nothing
            r = query(db, "SELECT id FROM bench_names WHERE grp = ? AND name = ?", (v.grp, v.name))
            bid = isempty(r) ? nothing : Int(r[1].id)
        end
        bid === nothing && (unmatched += 1; continue)
        upsert!(vstmt, (id, bid, v.time_ratio, v.time_tolerance, v.memory_ratio, v.memory_tolerance, v.verdict))
    end
    unmatched > 0 && @warn "Verdict rows whose benchmark name did not match" date_path unmatched
    err_stmt = upsert_stmt(db, "bench_errors", ["report_id", "bench_id"], ["error"]; seq=false)
    for e in errors
        id2 = e isa AbstractString ? parse_bench_id(e) : nothing
        id2 === nothing && continue
        bid = getid!(names, db, "bench_names", ("grp", "name"), id2)
        upsert!(err_stmt, (id, bid, String(e)))
    end
    return n
end

# Known reports and, per report, the statistics with detail rows
function known_reports(db)
    known = Dict{String,Set{String}}()
    for r in DBInterface.execute(db, "SELECT r.date, g.stat FROM bench_reports r LEFT JOIN bench_report_groups g ON g.report_id = r.id WHERE r.kind = 'daily'")
        s = get!(known, String(r.date), Set{String}())
        r.stat === missing || push!(s, String(r.stat))
    end
    return known
end

function main(args=ARGS)
    backfill_all = "--backfill-stats" in args
    db = open_db(Store.db_path(args); create=false)
    by_date_dir = ensure_clone()
    known = known_reports(db)
    @info "Known reports" count=length(known)
    all_dates = enumerate_report_dates(by_date_dir)

    required = backfill_all ? STATS : LEGACY_STATS
    new_dates = filter(d -> !issubset(required, get(known, date_path_to_date(d), Set{String}())), all_dates)
    @info "Reports to parse" count=length(new_dates)

    names = Dict{Tuple,Int}()
    n = source_run(db, "benchmarks") do
        written = 0
        for (i, date_path) in enumerate(new_dates)
            @info "Parsing report $i/$(length(new_dates)): $date_path"
            md = parse_report_md(by_date_dir, date_path)
            parsed = parse_tarball(by_date_dir, date_path, STATS)
            parsed === nothing && (@warn "No data extracted" date_path; continue)
            transaction(db) do
                written += write_report!(db, date_path, md, parsed, names, next_seq!(db))
            end
        end
        # Geomeans of the other estimates for group summaries written before
        # the columns existed, from the stored results (once per row)
        transaction(db) do
            DBInterface.execute(db, """
                UPDATE bench_report_groups AS g SET
                  gctime_geomean_ns = (SELECT exp(avg(ln(r.gctime_ns))) FROM bench_results r JOIN bench_names n ON n.id = r.bench_id
                                       WHERE r.report_id = g.report_id AND r.stat = g.stat AND n.grp = g.grp AND r.gctime_ns > 0),
                  gctime_count = (SELECT count(*) FROM bench_results r JOIN bench_names n ON n.id = r.bench_id
                                  WHERE r.report_id = g.report_id AND r.stat = g.stat AND n.grp = g.grp AND r.gctime_ns > 0),
                  memory_geomean_bytes = (SELECT exp(avg(ln(r.memory_bytes))) FROM bench_results r JOIN bench_names n ON n.id = r.bench_id
                                          WHERE r.report_id = g.report_id AND r.stat = g.stat AND n.grp = g.grp AND r.memory_bytes > 0),
                  memory_count = (SELECT count(*) FROM bench_results r JOIN bench_names n ON n.id = r.bench_id
                                  WHERE r.report_id = g.report_id AND r.stat = g.stat AND n.grp = g.grp AND r.memory_bytes > 0),
                  allocs_geomean = (SELECT exp(avg(ln(r.allocs))) FROM bench_results r JOIN bench_names n ON n.id = r.bench_id
                                    WHERE r.report_id = g.report_id AND r.stat = g.stat AND n.grp = g.grp AND r.allocs > 0),
                  allocs_count = (SELECT count(*) FROM bench_results r JOIN bench_names n ON n.id = r.bench_id
                                  WHERE r.report_id = g.report_id AND r.stat = g.stat AND n.grp = g.grp AND r.allocs > 0)
                WHERE g.memory_count IS NULL""")
            filled = Int(query(db, "SELECT changes() AS n")[1].n)
            filled > 0 && @info "Filled the other estimates' group geomeans" rows=filled
        end
        # Summary fields for known reports that lack them, from report.md
        # alone (cheap): the same backfill the file-based fetcher ran.
        transaction(db) do
            seq = next_seq!(db)
            stmt = DBInterface.prepare(db, "UPDATE bench_reports SET report_total = ?, report_regressions = ?, report_improvements = ?, " *
                                           "baseline_date = ?, baseline_commit_sha = COALESCE(baseline_commit_sha, ?), change_seq = ? WHERE id = ?")
            backfilled = 0
            for r in query(db, "SELECT id, path FROM bench_reports WHERE kind = 'daily' AND (report_total IS NULL OR baseline_date IS NULL)")
                date_path = replace(String(r.path), "by_date/" => "")
                date_path in new_dates && continue
                md = parse_report_md(by_date_dir, date_path)
                (md.total === nothing && md.baseline_date === nothing) && continue
                DBInterface.execute(stmt, (sql(md.total), sql(md.regressions), sql(md.improvements), sql(md.baseline_date),
                                           sql(md.baseline_commit), seq, Int(r.id)))
                backfilled += 1
            end
            backfilled > 0 && @info "Backfilled report summaries" count=backfilled
        end
        written
    end
    @info "Stored benchmark estimates" rows=n
    close(db)
    return 0
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
