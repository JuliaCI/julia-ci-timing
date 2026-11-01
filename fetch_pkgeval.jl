#!/usr/bin/env julia
# Fetch daily PkgEval results: Nanosoldier's from NanosoldierReports (until
# 2026-09), and the PkgEval farm's after that.
# Uses git ls-tree to enumerate Nanosoldier's dates, then fetches db.json files
# concurrently via GitHub raw content URLs. The farm lists its dailies in an
# index on its site and publishes each one's summary (daily.json, the shape of
# Nanosoldier's db.json) next to its report; both are stored under the same
# by_date/YYYY-MM/DD paths. Extracts per-date status counts (ok/fail/crash/skip/kill)
# and the per-package rows. Reports imported from the legacy summary file have
# no package rows; `--backfill-packages N` re-fetches the newest N such
# reports (about 1.5 MB and 13k rows each). Newer farm summaries also carry
# each failure's first error line and the failure signatures (failing packages
# grouped by a shared error line); `--backfill-signatures N` re-fetches the
# newest N farm reports stored without them.

using JSON3
using HTTP
using Dates

# The package has the store precompiled
using CITiming.Store
include(joinpath(@__DIR__, "db", "Fetch.jl"))
using SQLite, DBInterface

const CLONE_DIR = joinpath(@__DIR__, ".cache", "NanosoldierReports")
const RAW_BASE = "https://raw.githubusercontent.com/JuliaCI/NanosoldierReports/master/pkgeval/by_date"
const FARM_INDEX = get(ENV, "PKGEVAL_FARM_INDEX", "https://pkgeval-reports.julialang.org/daily/index.json")
const CONCURRENCY = 20

function enumerate_pkgeval_dates()
    @info "Enumerating pkgeval report dates..."
    output = read(`git -C $CLONE_DIR ls-tree -r --name-only HEAD pkgeval/by_date/`, String)
    dates = String[]
    for line in eachline(IOBuffer(output))
        endswith(line, "/db.json") || continue
        parts = split(line, "/")
        length(parts) >= 5 || continue
        push!(dates, "$(parts[3])/$(parts[4])")
    end
    sort!(dates)
    @info "Found $(length(dates)) pkgeval reports"
    return dates
end

# The farm's dailies as date path => (summary URL, Julia version). The summaries leave
# the version out (the index has it). Empty if the index can't be read, so a farm
# outage doesn't stop Nanosoldier's history from being ingested.
function farm_dailies()
    dailies = Dict{String,Tuple{String,String}}()
    try
        resp = http_get_retry(FARM_INDEX; connect_timeout=15, read_idle_timeout=30)
        resp.status == 200 || (@warn "Could not read the farm's daily index" status=resp.status; return dailies)
        for entry in JSON3.read(String(resp.body))
            date = Date(String(entry.date))
            dailies[Dates.format(date, dateformat"yyyy-mm/dd")] = (String(entry.summary), String(entry.version))
        end
    catch e
        @warn "Could not read the farm's daily index" error=e
    end
    return dailies
end

function fetch_db_json(date_path::String; client=nothing, url="$RAW_BASE/$date_path/db.json")
    try
        resp = http_get_retry(url; client, connect_timeout=15, read_idle_timeout=30)
        resp.status == 200 || return nothing
        return JSON3.read(String(resp.body))
    catch e
        @warn "Failed to fetch db.json" date_path error=e
        return nothing
    end
end

# Versions come as strings or as {major, minor, patch, prerelease} objects
function version_string(ver)
    ver === nothing && return ""
    ver isa AbstractString && return String(ver)
    major = get(ver, :major, 0)
    minor = get(ver, :minor, 0)
    patch = get(ver, :patch, 0)
    pre = get(ver, :prerelease, nothing)
    version_str = "$major.$minor.$patch"
    if pre !== nothing && !isempty(pre)
        version_str *= "-" * join(pre, ".")
    end
    return version_str
end

function count_statuses(db, date_path::String)
    tests = get(db, :tests, nothing)
    tests === nothing && return nothing

    counts = Dict{String,Int}("ok" => 0, "fail" => 0, "crash" => 0, "skip" => 0, "kill" => 0)
    for (_pkg, info) in pairs(tests)
        status = String(get(info, :status, "unknown"))
        if status == "test" || status == "ok"
            counts["ok"] += 1
        elseif haskey(counts, status)
            counts[status] += 1
        else
            counts["fail"] += 1
        end
    end

    date_str = String(get(db, :date, ""))
    build = get(db, :build, nothing)
    version_str = ""
    commit = ""
    if build !== nothing
        version_str = version_string(get(build, :version, nothing))
        sha = string(get(build, :sha, ""))
        commit = sha[1:min(8, length(sha))]
    end

    total = sum(values(counts))
    return Dict{String,Any}(
        "date" => date_str,
        "date_path" => date_path,
        "total" => total,
        "ok" => counts["ok"],
        "fail" => counts["fail"],
        "crash" => counts["crash"],
        "skip" => counts["skip"],
        "kill" => counts["kill"],
        "version" => version_str,
        "commit" => commit,
    )
end

# Per-package rows and per-reason counts for one report; the summary counts
# come from count_statuses above, unchanged.
function package_rows(db_json)
    tests = get(db_json, :tests, nothing)
    tests === nothing && return (NamedTuple[], Dict{Tuple{String,String},Int}())
    rows = NamedTuple[]
    reasons = Dict{Tuple{String,String},Int}()
    for (pkg, info) in pairs(tests)
        status = String(get(info, :status, "unknown"))
        status == "test" && (status = "ok")   # db.json's name for a passing package, as count_statuses reads it
        reason = get(info, :reason, nothing)
        reason = reason === nothing ? "" : String(reason)
        dur = get(info, :duration, nothing)
        version = version_string(get(info, :version, nothing))
        err = get(info, :error, nothing)
        push!(rows, (package = String(pkg), version = isempty(version) ? missing : version,
                     status = status, reason = isempty(reason) ? missing : reason,
                     duration_s = dur === nothing ? missing : Float64(dur),
                     error = err === nothing || isempty(err) ? missing : String(err)))
        reasons[(status, reason)] = get(reasons, (status, reason), 0) + 1
    end
    return rows, reasons
end

# The farm's failure signatures, or nothing for a summary without them
function signature_rows(db_json)
    sigs = get(db_json, :signatures, nothing)
    sigs === nothing && return nothing
    clusters = [(label = String(c.label), key = String(get(c, :key, c.label)), n = Int(c.n),
                 packages = JSON3.write([(name = String(p.name), log = String(get(p, :log, ""))) for p in get(c, :packages, [])]))
                for c in get(sigs, :clusters, [])]
    return (hard = Int(get(sigs, :hard, 0)), lines = Int(get(sigs, :lines, 0)), clusters)
end

const REPORT_COLS = ["kind", "date", "commit_sha", "julia_version", "total", "ok", "fail", "crash", "skip", "kill",
                     "signatures_hard", "signatures_lines"]

function write_reports!(db, reports)
    seq = next_seq!(db)
    rstmt = upsert_stmt(db, "pkgeval_reports", ["path"], REPORT_COLS)
    reason_stmt = upsert_stmt(db, "pkgeval_reasons", ["report_id", "status", "reason"], ["count"]; seq=false)
    result_stmt = upsert_stmt(db, "pkgeval_results", ["report_id", "package_id"], ["version", "status", "reason", "duration_s", "error"]; seq=false)
    sig_stmt = upsert_stmt(db, "pkgeval_signatures", ["report_id", "rank"], ["label", "key", "n", "packages"]; seq=false)
    packages = Dict{Tuple,Int}()
    n = 0
    for (summary, sha, pkgs, reasons, sigs) in reports
        path = "by_date/" * summary["date_path"]
        upsert!(rstmt, (path, "daily", summary["date"], sha, summary["version"], summary["total"], summary["ok"],
                        summary["fail"], summary["crash"], summary["skip"], summary["kill"],
                        sigs === nothing ? missing : sigs.hard, sigs === nothing ? missing : sigs.lines, seq))
        id = Int(query(db, "SELECT id FROM pkgeval_reports WHERE path = ?", (path,))[1].id)
        for ((status, reason), count) in reasons
            upsert!(reason_stmt, (id, status, reason, count))
        end
        for r in pkgs
            pid = getid!(packages, db, "packages", ("name",), (r.package,))
            upsert!(result_stmt, (id, pid, r.version, r.status, r.reason, r.duration_s, r.error))
            n += 1
        end
        if sigs !== nothing
            for (rank, c) in enumerate(sigs.clusters)
                upsert!(sig_stmt, (id, rank, c.label, c.key, c.n, c.packages))
            end
            # A summary fetched again may have fewer clusters than before
            DBInterface.execute(db, "DELETE FROM pkgeval_signatures WHERE report_id = ? AND rank > ?", (id, length(sigs.clusters)))
        end
    end
    return n
end

function backfill_count(args, flag="--backfill-packages")
    i = findfirst(==(flag), args)
    i === nothing && return 0
    return i < length(args) ? parse(Int, args[i+1]) : 365
end

# The fetches run inside the source's run record too, so a failed download
# shows on /healthz rather than leaving the last run marked ok
function ingest!(db, args)
    ensure_clone(CLONE_DIR)

    all_dates = enumerate_pkgeval_dates()
    # Known by path: a db.json without a date field would otherwise be new forever
    known_paths = Set(String(r.path) for r in query(db, "SELECT path FROM pkgeval_reports"))
    new_dates = filter(d -> "by_date/" * d ∉ known_paths, all_dates)
    # Nanosoldier's report wins if both ever cover a date
    farm = farm_dailies()
    nanosoldier_dates = Set(all_dates)
    filter!(((d, _),) -> d ∉ nanosoldier_dates, farm)
    append!(new_dates, sort!([d for d in keys(farm) if "by_date/" * d ∉ known_paths]))
    @info "New dates to process" count=length(new_dates) known=length(known_paths)
    backfill = backfill_count(args)
    if backfill > 0
        without = Set(String(r.path) for r in query(db, "SELECT r.path FROM pkgeval_reports r " *
            "WHERE r.kind = 'daily' AND NOT EXISTS (SELECT 1 FROM pkgeval_results p WHERE p.report_id = r.id)"))
        todo = filter(d -> "by_date/" * d in without, all_dates)
        todo = todo[max(1, end - backfill + 1):end]
        @info "Backfilling package rows" reports=length(todo) without_rows=length(without)
        append!(new_dates, todo)
    end
    # Farm summaries written before the farm grouped failures have no signatures,
    # and the reports stored from them are not fetched again on their own
    backfill = backfill_count(args, "--backfill-signatures")
    if backfill > 0
        without = Set(String(r.path) for r in query(db, "SELECT path FROM pkgeval_reports WHERE kind = 'daily' AND signatures_hard IS NULL"))
        todo = sort!([d for d in keys(farm) if "by_date/" * d in without && d ∉ new_dates])
        todo = todo[max(1, end - backfill + 1):end]
        @info "Backfilling failure signatures" reports=length(todo)
        append!(new_dates, todo)
    end

    done = Threads.Atomic{Int}(0)
    total = length(new_dates)
    # One client for the concurrent fetches, closed afterwards: its pooled
    # keep-alive connections would otherwise die noisily when the process exits
    client = HTTP.Client()
    results = asyncmap(new_dates; ntasks=CONCURRENCY) do date_path
        from_farm = haskey(farm, date_path)
        db_json = from_farm ? fetch_db_json(date_path; client, url=farm[date_path][1]) :
                              fetch_db_json(date_path; client)
        n = Threads.atomic_add!(done, 1) + 1
        if n % 50 == 0 || n == total
            @info "Progress: $n/$total"
        end
        db_json === nothing && return nothing
        summary = count_statuses(db_json, date_path)
        summary === nothing && return nothing
        from_farm && isempty(summary["version"]) && (summary["version"] = farm[date_path][2])
        build = get(db_json, :build, nothing)
        sha = build === nothing ? "" : string(get(build, :sha, ""))
        pkgs, reasons = package_rows(db_json)
        return (summary, sha, pkgs, reasons, signature_rows(db_json))
    end
    close(client)
    reports = filter(!isnothing, results)

    n = let
        transaction(db) do
            write_reports!(db, reports)
        end
    end
    @info "Stored pkgeval reports" reports=length(reports) package_rows=n
    return n
end

function main(args=ARGS)
    db = open_db(Store.db_path(args); create=false)
    source_run(() -> ingest!(db, args), db, "pkgeval")
    close(db)
    return 0
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
