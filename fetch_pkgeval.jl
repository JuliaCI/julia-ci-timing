#!/usr/bin/env julia
# Fetch PkgEval results from NanosoldierReports
# Uses git ls-tree to enumerate dates, then fetches db.json files concurrently
# via GitHub raw content URLs. Extracts per-date status counts (ok/fail/crash/skip/kill).

using JSON3
using HTTP
using Dates
using CodecZlib: GzipCompressor, GzipDecompressor

const REPORTS_REPO = "https://github.com/JuliaCI/NanosoldierReports.git"
const CLONE_DIR = joinpath(tempdir(), "NanosoldierReports")
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

function fetch_db_json(date_path::String)
    url = "$RAW_BASE/$date_path/db.json"
    try
        resp = HTTP.get(url; retry=true, retries=3, connect_timeout=15, readtimeout=30,
                        status_exception=false)
        resp.status == 200 || return nothing
        return JSON3.read(String(resp.body))
    catch e
        @warn "Failed to fetch db.json" date_path error=e
        return nothing
    end
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
        ver = get(build, :version, nothing)
        if ver !== nothing
            if ver isa AbstractString
                version_str = String(ver)
            else
                major = get(ver, :major, 0)
                minor = get(ver, :minor, 0)
                patch = get(ver, :patch, 0)
                pre = get(ver, :prerelease, nothing)
                version_str = "$major.$minor.$patch"
                if pre !== nothing && !isempty(pre)
                    version_str *= "-" * join(pre, ".")
                end
            end
        end
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

function load_existing(output_dir)
    path_gz = joinpath(output_dir, "pkgeval_summary.json.gz")
    try
        if isfile(path_gz)
            data = JSON3.read(transcode(GzipDecompressor, read(path_gz)))
            reports = get(data, :reports, [])
            known = Set(String(get(r, :date, "")) for r in reports)
            @info "Loaded existing pkgeval summary" reports=length(reports)
            return (data, known)
        end
    catch e
        @warn "Failed to load existing summary" error=e
    end
    return (nothing, Set{String}())
end

function main()
    output_dir = "data"
    mkpath(output_dir)

    ensure_clone()

    all_dates = enumerate_pkgeval_dates()
    existing_data, known_dates = load_existing(output_dir)

    new_dates = filter(d -> date_path_to_date(d) ∉ known_dates, all_dates)
    @info "New dates to process" count=length(new_dates)

    done = Threads.Atomic{Int}(0)
    total = length(new_dates)
    results = asyncmap(new_dates; ntasks=CONCURRENCY) do date_path
        db = fetch_db_json(date_path)
        n = Threads.atomic_add!(done, 1) + 1
        if n % 50 == 0 || n == total
            @info "Progress: $n/$total"
        end
        db === nothing && return nothing
        return count_statuses(db, date_path)
    end
    new_reports = filter(!isnothing, results)

    reports_by_date = Dict{String,Any}()
    if existing_data !== nothing
        for r in get(existing_data, :reports, [])
            d = String(get(r, :date, ""))
            isempty(d) && continue
            reports_by_date[d] = Dict{String,Any}(String(k) => v for (k, v) in pairs(r))
        end
    end
    for r in new_reports
        isempty(r["date"]) && continue
        reports_by_date[r["date"]] = r
    end

    sorted_reports = [reports_by_date[k] for k in sort(collect(keys(reports_by_date)))]

    summary = Dict{String,Any}(
        "generated_at" => Dates.format(now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SSZ"),
        "reports" => sorted_reports,
    )

    output_path = joinpath(output_dir, "pkgeval_summary.json.gz")
    json_bytes = Vector{UInt8}(JSON3.write(summary))
    gz_bytes = transcode(GzipCompressor, json_bytes)
    write(output_path, gz_bytes)
    @info "Wrote $(length(sorted_reports)) reports to $output_path"
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
