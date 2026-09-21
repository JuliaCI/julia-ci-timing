#!/usr/bin/env julia
# Fetch PkgEval results from NanosoldierReports
# Uses git ls-tree to enumerate dates, then fetches db.json files concurrently
# via GitHub raw content URLs. Extracts per-date status counts (ok/fail/crash/skip/kill).

using JSON3
using HTTP
using Dates

include(joinpath(@__DIR__, "db", "Store.jl"))
using .Store
using SQLite, DBInterface

const REPORTS_REPO = "https://github.com/JuliaCI/NanosoldierReports.git"
const CLONE_DIR = joinpath(@__DIR__, ".cache", "NanosoldierReports")
const RAW_BASE = "https://raw.githubusercontent.com/JuliaCI/NanosoldierReports/master/pkgeval/by_date"
const CONCURRENCY = 20

function ensure_clone()
    if isdir(joinpath(CLONE_DIR, ".git"))
        @info "Updating existing clone..." dir=CLONE_DIR
        run(`git -C $CLONE_DIR fetch --depth 1 origin`)
        run(`git -C $CLONE_DIR reset --hard origin/master`)
    else
        @info "Cloning NanosoldierReports (sparse, tree-only)..." dir=CLONE_DIR
        rm(CLONE_DIR; force=true, recursive=true)
        run(`git clone --depth 1 --filter=blob:none --sparse $REPORTS_REPO $CLONE_DIR`)
    end
end

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

function date_path_to_date(path::String)
    parts = split(path, "/")
    "$(parts[1])-$(lpad(parts[2], 2, '0'))"
end


# GET with retries on connection errors, 429 and 5xx, honouring Retry-After
# when the server sends one. HTTP.jl's own retry layer never sees a status
# code once status_exception is off, so this loop covers those.
function http_get_retry(url, headers=Pair{String,String}[]; attempts=4, kwargs...)
    local resp
    for attempt in 1:attempts
        resp = try
            HTTP.get(url, headers; status_exception=false, retry=false, kwargs...)
        catch e
            attempt == attempts && rethrow()
            @warn "Request failed, retrying" url attempt error=e
            sleep(2.0^attempt)
            continue
        end
        (resp.status == 429 || resp.status >= 500) || return resp
        attempt == attempts && return resp
        wait = something(tryparse(Int, HTTP.header(resp, "Retry-After")), 2^attempt)
        @warn "Retrying after HTTP $(resp.status)" url wait attempt
        sleep(wait)
    end
    return resp
end

function fetch_db_json(date_path::String)
    url = "$RAW_BASE/$date_path/db.json"
    try
        resp = http_get_retry(url; connect_timeout=15, readtimeout=30)
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
        reason = get(info, :reason, nothing)
        reason = reason === nothing ? "" : String(reason)
        dur = get(info, :duration, nothing)
        version = version_string(get(info, :version, nothing))
        push!(rows, (package = String(pkg), version = isempty(version) ? missing : version,
                     status = status, reason = isempty(reason) ? missing : reason,
                     duration_s = dur === nothing ? missing : Float64(dur)))
        reasons[(status, reason)] = get(reasons, (status, reason), 0) + 1
    end
    return rows, reasons
end

const REPORT_COLS = ["kind", "date", "commit_sha", "julia_version", "total", "ok", "fail", "crash", "skip", "kill"]

function write_reports!(db, reports)
    seq = next_seq!(db)
    rstmt = upsert_stmt(db, "pkgeval_reports", ["path"], REPORT_COLS)
    reason_stmt = upsert_stmt(db, "pkgeval_reasons", ["report_id", "status", "reason"], ["count"]; seq=false)
    result_stmt = upsert_stmt(db, "pkgeval_results", ["report_id", "package_id"], ["version", "status", "reason", "duration_s"]; seq=false)
    packages = Dict{Tuple,Int}()
    n = 0
    for (summary, sha, pkgs, reasons) in reports
        path = "by_date/" * summary["date_path"]
        upsert!(rstmt, (path, "daily", summary["date"], sha, summary["version"], summary["total"], summary["ok"],
                        summary["fail"], summary["crash"], summary["skip"], summary["kill"], seq))
        id = Int(query(db, "SELECT id FROM pkgeval_reports WHERE path = ?", (path,))[1].id)
        for ((status, reason), count) in reasons
            upsert!(reason_stmt, (id, status, reason, count))
        end
        for r in pkgs
            pid = getid!(packages, db, "packages", ("name",), (r.package,))
            upsert!(result_stmt, (id, pid, r.version, r.status, r.reason, r.duration_s))
            n += 1
        end
    end
    return n
end

function main(args=ARGS)
    db = open_db(Store.db_path(args); create=false)
    ensure_clone()

    all_dates = enumerate_pkgeval_dates()
    known_dates = Set(String(r.date) for r in query(db, "SELECT date FROM pkgeval_reports"))
    new_dates = filter(d -> date_path_to_date(d) ∉ known_dates, all_dates)
    @info "New dates to process" count=length(new_dates) known=length(known_dates)

    done = Threads.Atomic{Int}(0)
    total = length(new_dates)
    results = asyncmap(new_dates; ntasks=CONCURRENCY) do date_path
        db_json = fetch_db_json(date_path)
        n = Threads.atomic_add!(done, 1) + 1
        if n % 50 == 0 || n == total
            @info "Progress: $n/$total"
        end
        db_json === nothing && return nothing
        summary = count_statuses(db_json, date_path)
        summary === nothing && return nothing
        build = get(db_json, :build, nothing)
        sha = build === nothing ? "" : string(get(build, :sha, ""))
        pkgs, reasons = package_rows(db_json)
        return (summary, sha, pkgs, reasons)
    end
    # The concurrent fetches leave pooled keep-alive connections whose idle
    # monitors otherwise die noisily when the process exits
    HTTP.Connections.closeall()
    reports = filter(!isnothing, results)

    n = source_run(db, "pkgeval") do
        transaction(db) do
            write_reports!(db, reports)
        end
    end
    @info "Stored pkgeval reports" reports=length(reports) package_rows=n
    close(db)
    return 0
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
