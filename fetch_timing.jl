#!/usr/bin/env julia

# Fetch Julia CI timing data from Buildkite API into the database (db/).
# Buildkite only retains a window of builds, so the database must already
# hold the history (db/import_legacy.jl seeds it); the site's files are
# rendered from it by db/export.jl.

using HTTP
using JSON3
using Dates

include(joinpath(@__DIR__, "db", "Store.jl"))
using .Store
using SQLite, DBInterface

const BUILDKITE_ORG = "julialang"
const PIPELINE = "julia-master"
const API_BASE = "https://api.buildkite.com/v2"

function get_token()
    token = get(ENV, "BUILDKITE_API_TOKEN", nothing)
    if token === nothing
        token_file = joinpath(homedir(), ".buildkite_token")
        if isfile(token_file)
            token = strip(read(token_file, String))
        end
    end
    token === nothing && error("Set BUILDKITE_API_TOKEN env var or create ~/.buildkite_token")
    return token
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

function api_get(endpoint; token=get_token(), params=Dict())
    url = "$API_BASE/$endpoint"
    if !isempty(params)
        query = join(["$k=$v" for (k, v) in params], "&")
        url = "$url?$query"
    end
    resp = http_get_retry(url, ["Authorization" => "Bearer $token"])
    if resp.status != 200
        @warn "API request failed" url resp.status String(resp.body)
        return nothing
    end
    return JSON3.read(resp.body)
end

const SCHEDULED_PIPELINE = "julia-master-scheduled"
# Since July 2026 Julia CI runs on the julia-ci pipeline (julia-master and
# julia-master-scheduled are dead; the old scheduled pipeline still fires
# daily but fails at launch). See JuliaCI/julia-buildkite#544.
const CI_PIPELINE = "julia-ci"

function fetch_pipeline_builds(pipeline; branch="master", per_page=100, max_pages=30, fully_captured_below=0)
    builds = []
    for page in 1:max_pages
        params = Dict(
            "branch" => branch,
            "per_page" => per_page,
            "page" => page
        )
        data = api_get("organizations/$BUILDKITE_ORG/pipelines/$pipeline/builds"; params)
        if data === nothing
            # Merging a partial listing would let the next run's threshold skip
            # the builds behind the failed page for good; try again next run
            @warn "Page $page of $pipeline failed; skipping this pipeline for this run"
            return nothing
        end
        isempty(data) && break

        new_in_page = 0
        oldest_in_page = typemax(Int)
        for build in data
            oldest_in_page = min(oldest_in_page, build.number)
            # Only skip builds that are definitely fully captured (below threshold)
            if build.number >= fully_captured_below
                push!(builds, build)
                new_in_page += 1
            end
        end
        @info "Fetched page $page ($pipeline)" new_or_updated=new_in_page skipped=length(data)-new_in_page oldest=oldest_in_page threshold=fully_captured_below

        # If we've gone past the threshold and all builds are known, we can stop
        if oldest_in_page < fully_captured_below && new_in_page == 0
            @info "Reached fully captured region, stopping early"
            break
        end
    end
    return builds
end

function parse_datetime(s::AbstractString)
    # Buildkite returns ISO 8601 timestamps
    return DateTime(s[1:19], dateformat"yyyy-mm-ddTHH:MM:SS")
end
parse_datetime(::Nothing) = nothing

function job_duration_seconds(job)
    started = get(job, :started_at, nothing)
    finished = get(job, :finished_at, nothing)
    (started === nothing || finished === nothing) && return nothing
    start_dt = parse_datetime(started)
    end_dt = parse_datetime(finished)
    return Dates.value(end_dt - start_dt) / 1000  # milliseconds to seconds
end


# Buildkite ISO timestamp to the store's second-precision UTC form
at(x) = x === nothing ? missing : Store.iso(Store.parse_upstream(String(x)))
str_or_missing(x) = x === nothing ? missing : String(x)

meta_value(tags, key) = (i = findfirst(t -> startswith(String(t), key * "="), tags);
                         i === nothing ? missing : String(tags[i])[length(key)+2:end])

"""
    extract_builds_and_jobs(builds, pipeline) -> (build_rows, job_rows)

One row per build and one per finished script job. The filters (script
jobs only, no musl, started and finished) and the per-name `retry`
ordinal within a build are unchanged from the file-based fetcher; the
rest of the Buildkite payload the schema has columns for is kept too.
"""
function extract_builds_and_jobs(builds, pipeline::String)
    build_rows = NamedTuple[]
    job_rows = NamedTuple[]
    for build in builds
        sha = String(build.commit)
        raw_message = get(build, :message, "")
        message = isnothing(raw_message) ? "" : split(String(raw_message), '\n')[1]
        message = length(message) > 80 ? first(message, 77) * "..." : message
        creator = get(build, :creator, nothing)
        author = creator === nothing ? "" : something(get(creator, :name, ""), "")
        pr = get(build, :pull_request, nothing)
        pr_number = pr === nothing ? missing : tryparse(Int, String(something(get(pr, :id, nothing), "")))
        push!(build_rows, (
            pipeline = pipeline, number = Int(build.number),
            commit_prefix = sha[1:min(8, length(sha))], commit_sha = length(sha) == 40 ? sha : missing,
            branch = str_or_missing(get(build, :branch, nothing)), state = str_or_missing(get(build, :state, nothing)),
            source = str_or_missing(get(build, :source, nothing)),
            blocked = get(build, :blocked, nothing) === nothing ? missing : Int(build.blocked),
            pull_request = pr_number === nothing ? missing : pr_number,
            author = String(author), message = String(message),
            created_at = at(build.created_at), scheduled_at = at(get(build, :scheduled_at, nothing)),
            started_at = at(get(build, :started_at, nothing)), finished_at = at(get(build, :finished_at, nothing)),
            web_url = str_or_missing(get(build, :web_url, nothing)),
            raw = JSON3.write(build)))

        job_retry_counts = Dict{String,Int}()
        for job in get(build, :jobs, [])
            name = get(job, :name, nothing)
            name === nothing && continue
            name = String(name)
            get(job, :type, nothing) == "script" || continue
            occursin("musl", name) && continue
            duration = job_duration_seconds(job)
            duration === nothing && continue
            agent_info = get(job, :agent, nothing)
            tags = agent_info === nothing ? [] : something(get(agent_info, :meta_data, nothing), [])
            queue = meta_value(tags, "queue")
            if queue === missing
                queue = meta_value(something(get(job, :agent_query_rules, nothing), []), "queue")
            end
            retry_num = get(job_retry_counts, name, 0)
            job_retry_counts[name] = retry_num + 1
            push!(job_rows, (
                pipeline = pipeline, number = Int(build.number), name = name, retry = retry_num,
                job_uuid = str_or_missing(get(job, :id, nothing)), step_key = str_or_missing(get(job, :step_key, nothing)),
                agent_hostname = agent_info === nothing ? "" : String(something(get(agent_info, :hostname, nothing), "")),
                agent_name = agent_info === nothing ? missing : str_or_missing(get(agent_info, :name, nothing)),
                queue = queue,
                state = String(get(job, :state, "unknown")),
                exit_status = get(job, :exit_status, nothing) === nothing ? missing : Int(job.exit_status),
                soft_failed = get(job, :soft_failed, nothing) === nothing ? missing : Int(job.soft_failed),
                retried = get(job, :retried, nothing) === nothing ? missing : Int(job.retried),
                retries_count = get(job, :retries_count, nothing) === nothing ? missing : Int(job.retries_count),
                retry_type = str_or_missing(get(job, :retry_type, nothing)),
                parallel_group_index = get(job, :parallel_group_index, nothing) === nothing ? missing : Int(job.parallel_group_index),
                # 0.1 s, as the file-based fetcher stored it; started_at and
                # finished_at keep the full precision
                duration_s = round(duration; digits=1),
                created_at = at(get(job, :created_at, nothing)), scheduled_at = at(get(job, :scheduled_at, nothing)),
                runnable_at = at(get(job, :runnable_at, nothing)), started_at = at(job.started_at), finished_at = at(job.finished_at),
                web_url = str_or_missing(get(job, :web_url, nothing))))
        end
    end
    return build_rows, job_rows
end

rows(db, sql, params=()) = SQLite.Tables.rowtable(DBInterface.execute(db, sql, params))

# Builds below this number are fully captured: the oldest build among the
# newest `lookback` records of the key jobs, per pipeline (records ordered
# as the export orders them).
function fully_captured_threshold(db; key_jobs=[":linux: test x86_64-linux-gnu", ":linux: build x86_64-linux-gnu"], lookback=50)
    mins = Dict{String,Int}()
    for job_name in key_jobs, pipeline in (PIPELINE, SCHEDULED_PIPELINE, CI_PIPELINE)
        r = rows(db, "SELECT MIN(number) AS m FROM (SELECT b.number FROM jobs j JOIN builds b ON b.id = j.build_id " *
                     "WHERE j.name = ? AND b.pipeline = ? ORDER BY b.created_at DESC, j.retry ASC, b.number DESC LIMIT ?)",
                 (job_name, pipeline, lookback))
        m = r[1].m
        m === missing && continue
        mins[pipeline] = min(get(mins, pipeline, typemax(Int)), Int(m))
    end
    return (master=get(mins, PIPELINE, 0), scheduled=get(mins, SCHEDULED_PIPELINE, 0), ci=get(mins, CI_PIPELINE, 0))
end

const BUILD_COLS = ["commit_prefix", "commit_sha", "branch", "state", "source", "blocked", "pull_request", "author", "message",
                    "created_at", "scheduled_at", "started_at", "finished_at", "web_url"]
const JOB_COLS = ["job_uuid", "step_key", "agent_hostname", "agent_name", "queue", "state", "exit_status", "soft_failed",
                  "retried", "retries_count", "retry_type", "parallel_group_index", "duration_s",
                  "created_at", "scheduled_at", "runnable_at", "started_at", "finished_at", "web_url"]

# Upsert builds and jobs. A re-fetched build replaces its jobs by
# (name, retry) and keeps any old rows the new payload no longer has, as the
# file merge did.
function write_timings!(db, build_rows, job_rows)
    seq = next_seq!(db)
    bstmt = upsert_stmt(db, "builds", ["pipeline", "number"], BUILD_COLS)
    raw_stmt = DBInterface.prepare(db, "INSERT OR REPLACE INTO raw_builds (pipeline, number, fetched_at, json_zst) VALUES (?, ?, ?, ?)")
    fetched_at = iso_now()
    ids = Dict{Tuple{String,Int},Int}()
    for b in build_rows
        upsert!(bstmt, (b.pipeline, b.number, (getproperty(b, Symbol(c)) for c in BUILD_COLS)..., seq))
        DBInterface.execute(raw_stmt, (b.pipeline, b.number, fetched_at, compress_zst(b.raw)))
        ids[(b.pipeline, b.number)] = Int(rows(db, "SELECT id FROM builds WHERE pipeline = ? AND number = ?", (b.pipeline, b.number))[1].id)
    end
    jstmt = upsert_stmt(db, "jobs", ["build_id", "name", "retry"], JOB_COLS)
    # A UUID already stored under another (name, retry) of the same build
    # would violate the unique index; drop that row first (the payload's
    # ordinal wins, as it does for the file merge).
    for b in build_rows
        id = ids[(b.pipeline, b.number)]
        DBInterface.execute(db, "DELETE FROM jobs WHERE build_id = ? AND job_uuid IS NOT NULL AND job_uuid NOT IN " *
                                "(SELECT value FROM json_each(?)) AND (name, retry) IN " *
                                "(SELECT json_extract(value, '\$.n'), json_extract(value, '\$.r') FROM json_each(?))",
                            (id, JSON3.write([j.job_uuid for j in job_rows if j.pipeline == b.pipeline && j.number == b.number && j.job_uuid !== missing]),
                                 JSON3.write([Dict("n" => j.name, "r" => j.retry) for j in job_rows if j.pipeline == b.pipeline && j.number == b.number])))
    end
    for j in job_rows
        upsert!(jstmt, (ids[(j.pipeline, j.number)], j.name, j.retry, (getproperty(j, Symbol(c)) for c in JOB_COLS)..., seq))
    end
    return length(job_rows)
end

function write_coverage!(db, coverage)
    seq = next_seq!(db)
    stmt = upsert_stmt(db, "coverage", ["commit_sha"], ["measured_at", "codecov", "coveralls"])
    for (sha, c) in coverage
        upsert!(stmt, (sha, something(c["date"], missing), something(c["codecov"], missing), something(c["coveralls"], missing), seq))
    end
    return length(coverage)
end

# Existing values are kept and only missing provider values filled in, so
# the whole table is loaded first (a few thousand rows).
function fetch_coverage_data(db; max_pages=20)
    coverage = Dict{String, Any}()
    for r in rows(db, "SELECT commit_sha, measured_at, codecov, coveralls FROM coverage")
        coverage[String(r.commit_sha)] = Dict(
            "coveralls" => r.coveralls === missing ? nothing : r.coveralls,
            "codecov" => r.codecov === missing ? nothing : r.codecov,
            "date" => r.measured_at === missing ? nothing : String(r.measured_at)
        )
    end
    
    @info "Loaded existing coverage data" entries=length(coverage)
    
    # Fetch new data from Coveralls
    try
        for page in 1:max_pages
            url = "https://coveralls.io/github/JuliaLang/julia.json?page=$page"
            resp = HTTP.get(url; status_exception=false)
            if resp.status != 200
                @warn "Coveralls API request failed" page resp.status
                break
            end
            
            data = JSON3.read(resp.body)
            builds = get(data, :builds, [])
            isempty(builds) && break
            
            new_in_page = 0
            for build in builds
                commit = get(build, :commit_sha, nothing)
                commit === nothing && continue
                commit = String(commit)
                
                # Add or update entry
                if !haskey(coverage, commit)
                    coverage[commit] = Dict(
                        "coveralls" => get(build, :covered_percent, nothing),
                        "codecov" => nothing,
                        "date" => get(build, :created_at, nothing)
                    )
                    new_in_page += 1
                elseif coverage[commit]["coveralls"] === nothing
                    coverage[commit]["coveralls"] = get(build, :covered_percent, nothing)
                    new_in_page += 1
                end
            end
            
            @info "Fetched Coveralls page $page" new_entries=new_in_page
            
            # Stop if no new data
            new_in_page == 0 && page > 2 && break
        end
    catch e
        @warn "Failed to fetch coverage data from Coveralls" error=e
    end
    
    # Fetch data from Codecov API
    try
        page = 1
        while page <= max_pages
            url = "https://codecov.io/api/v2/github/JuliaLang/repos/julia/commits?branch=master&page=$page&page_size=100"
            resp = HTTP.get(url; status_exception=false)
            if resp.status != 200
                @warn "Codecov API request failed" page resp.status
                break
            end
            
            data = JSON3.read(resp.body)
            results = get(data, :results, [])
            isempty(results) && break
            
            new_in_page = 0
            for commit_data in results
                commit = get(commit_data, :commitid, nothing)
                commit === nothing && continue
                commit = String(commit)
                
                totals = get(commit_data, :totals, nothing)
                cov_percent = totals !== nothing ? get(totals, :coverage, nothing) : nothing
                
                # Add or update entry
                if !haskey(coverage, commit)
                    coverage[commit] = Dict(
                        "coveralls" => nothing,
                        "codecov" => cov_percent,
                        "date" => get(commit_data, :timestamp, nothing)
                    )
                    new_in_page += 1
                elseif coverage[commit]["codecov"] === nothing && cov_percent !== nothing
                    coverage[commit]["codecov"] = cov_percent
                    new_in_page += 1
                end
            end
            
            @info "Fetched Codecov page $page" new_entries=new_in_page
            
            # Stop if no new data
            new_in_page == 0 && page > 2 && break
            
            # Check if there are more pages
            get(data, :next, nothing) === nothing && break
            page += 1
        end
    catch e
        @warn "Failed to fetch coverage data from Codecov" error=e
    end
    
    return coverage
end

function main(args=ARGS)
    db = open_db(Store.db_path(args); create=false)
    threshold = fully_captured_threshold(db)
    @info "Fully captured threshold" master=threshold.master scheduled=threshold.scheduled ci=threshold.ci

    @info "Fetching builds from Buildkite..."
    ci_builds = something(fetch_pipeline_builds(CI_PIPELINE; max_pages=30, fully_captured_below=threshold.ci), [])
    @info "Fetched julia-ci builds" count=length(ci_builds)

    # The legacy pipelines stopped receiving builds in July 2026; once their
    # history is in the database there is nothing to page for
    builds = threshold.master > 0 ? [] :
        something(fetch_pipeline_builds(PIPELINE; max_pages=30, fully_captured_below=threshold.master), [])
    @info "Fetched julia-master builds" count=length(builds)

    scheduled_builds = threshold.scheduled > 0 ? [] :
        something(fetch_pipeline_builds(SCHEDULED_PIPELINE; max_pages=10, fully_captured_below=threshold.scheduled), [])
    @info "Fetched julia-master-scheduled builds" count=length(scheduled_builds)

    if isempty(ci_builds) && isempty(builds) && isempty(scheduled_builds) &&
       threshold.master == 0 && threshold.scheduled == 0 && threshold.ci == 0
        @error "No builds fetched and no existing data - check your token and permissions"
        return 1
    end

    build_rows = NamedTuple[]
    job_rows = NamedTuple[]
    for (pipeline, pipeline_builds) in ((PIPELINE, builds), (SCHEDULED_PIPELINE, scheduled_builds), (CI_PIPELINE, ci_builds))
        b, j = extract_builds_and_jobs(pipeline_builds, pipeline)
        append!(build_rows, b)
        append!(job_rows, j)
    end
    @info "Extracted" builds=length(build_rows) jobs=length(job_rows)

    @info "Fetching coverage data..."
    coverage = fetch_coverage_data(db)
    @info "Coverage data" entries=length(coverage)

    source_run(db, TIMING_SOURCE) do
        transaction(db) do
            write_timings!(db, build_rows, job_rows) + write_coverage!(db, coverage)
        end
    end
    close(db)
    return 0
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
