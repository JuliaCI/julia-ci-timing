#!/usr/bin/env julia

# Fetch Julia CI timing data from Buildkite API into the database (db/).
# Buildkite only retains a window of builds, so the database must already
# hold the history (the host restores it from the latest backup); the
# site reads it through db/serve.jl and db/export.jl renders the extracts.

using HTTP
using JSON3
using Dates

include(joinpath(@__DIR__, "db", "Store.jl"))
include(joinpath(@__DIR__, "db", "Fetch.jl"))
using .Store
using SQLite, DBInterface

const PIPELINE = "julia-master"

const SCHEDULED_PIPELINE = "julia-master-scheduled"
# Since July 2026 Julia CI runs on the julia-ci pipeline (julia-master and
# julia-master-scheduled are dead; the old scheduled pipeline still fires
# daily but fails at launch). See JuliaCI/julia-buildkite#544.
const CI_PIPELINE = "julia-ci"

# A failed page throws: merging a partial listing would let the next run's
# threshold skip the builds behind the failed page for good
function fetch_pipeline_builds(pipeline; branch="master", max_pages=30, fully_captured_below=0)
    builds = []
    buildkite_pages("organizations/$BUILDKITE_ORG/pipelines/$pipeline/builds", ["branch" => branch]; max_pages) do data, page
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
            return :stop
        end
    end
    return builds
end

function job_duration_seconds(job)
    started = get(job, :started_at, nothing)
    finished = get(job, :finished_at, nothing)
    (started === nothing || finished === nothing) && return nothing
    start_dt = Store.parse_upstream(String(started))
    end_dt = Store.parse_upstream(String(finished))
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

rows(db, sql, params=()) = query(db, sql, params)

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
    # Rewritten only when the payload differs, so a run that saw nothing new
    # commits nothing (and the change sequence stays put)
    raw_stmt = DBInterface.prepare(db, "INSERT INTO raw_builds (pipeline, number, fetched_at, json_zst) VALUES (?, ?, ?, ?) " *
                                       "ON CONFLICT (pipeline, number) DO UPDATE SET fetched_at = excluded.fetched_at, json_zst = excluded.json_zst " *
                                       "WHERE raw_builds.json_zst IS NOT excluded.json_zst")
    fetched_at = iso_now()
    ids = Dict{Tuple{String,Int},Int}()
    for b in build_rows
        upsert!(bstmt, (b.pipeline, b.number, (getproperty(b, Symbol(c)) for c in BUILD_COLS)..., seq))
        DBInterface.execute(raw_stmt, (b.pipeline, b.number, fetched_at, compress_zst(b.raw)))
        ids[(b.pipeline, b.number)] = Int(rows(db, "SELECT id FROM builds WHERE pipeline = ? AND number = ?", (b.pipeline, b.number))[1].id)
    end
    jstmt = upsert_stmt(db, "jobs", ["build_id", "name", "retry"], JOB_COLS)
    # The upsert is keyed on (build, name, retry) but job_uuid is unique
    # too, and a same-name job's ordinal can shift between fetches. Two
    # rows of the build would then collide with the payload: one holding a
    # UUID the payload no longer has in a slot the payload fills, and one
    # holding a payload UUID in a slot other than the payload's for it.
    # Drop both first (the payload's ordinal wins, as it did for the file
    # merge), or the INSERT would fail and roll back the whole run.
    for b in build_rows
        id = ids[(b.pipeline, b.number)]
        slots = JSON3.write([Dict("u" => j.job_uuid === missing ? nothing : j.job_uuid, "n" => j.name, "r" => j.retry)
                             for j in job_rows if j.pipeline == b.pipeline && j.number == b.number])
        DBInterface.execute(db, "DELETE FROM jobs WHERE build_id = ? AND job_uuid IS NOT NULL AND job_uuid NOT IN " *
                                "(SELECT json_extract(value, '\$.u') FROM json_each(?) WHERE json_extract(value, '\$.u') IS NOT NULL) " *
                                "AND (name, retry) IN (SELECT json_extract(value, '\$.n'), json_extract(value, '\$.r') FROM json_each(?))",
                            (id, slots, slots))
        DBInterface.execute(db, "DELETE FROM jobs WHERE build_id = ? AND job_uuid IS NOT NULL AND EXISTS " *
                                "(SELECT 1 FROM json_each(?) e WHERE json_extract(e.value, '\$.u') = jobs.job_uuid " *
                                "AND (json_extract(e.value, '\$.n') != jobs.name OR json_extract(e.value, '\$.r') != jobs.retry))",
                            (id, slots))
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
        measured_at = c["date"] === nothing ? missing : Store.iso(Store.parse_upstream(String(c["date"])))
        upsert!(stmt, (sha, measured_at, something(c["codecov"], missing), something(c["coveralls"], missing), seq))
    end
    return length(coverage)
end

# Existing Coveralls values are kept and only missing ones filled in; Codecov
# values are refreshed. The whole table is loaded first (a few thousand rows).
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
            resp = http_get_retry(url)
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
            resp = http_get_retry(url)
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
                # Codecov updates a commit's total as each platform's upload is processed,
                # so a value stored earlier may be partial.
                elseif cov_percent !== nothing && coverage[commit]["codecov"] != cov_percent
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

# A listing that failed (bad token, Buildkite down) is a failed run,
# recorded in source_runs so /healthz and the daily check see it, not an
# empty one that would count as success
function list_builds(pipeline; kwargs...)
    builds = fetch_pipeline_builds(pipeline; kwargs...)
    @info "Fetched $pipeline builds" count=length(builds)
    return builds
end

function main(args=ARGS)
    db = open_db(Store.db_path(args); create=false)
    source_run(db, TIMING_SOURCE) do
        run!(db)
    end
    close(db)
    return 0
end

function run!(db)
    threshold = fully_captured_threshold(db)
    @info "Fully captured threshold" master=threshold.master scheduled=threshold.scheduled ci=threshold.ci

    @info "Fetching builds from Buildkite..."
    ci_builds = list_builds(CI_PIPELINE; max_pages=30, fully_captured_below=threshold.ci)

    # The legacy pipelines stopped receiving builds in July 2026; once their
    # history is in the database there is nothing to page for
    builds = threshold.master > 0 ? [] : list_builds(PIPELINE; max_pages=30, fully_captured_below=threshold.master)
    scheduled_builds = threshold.scheduled > 0 ? [] : list_builds(SCHEDULED_PIPELINE; max_pages=10, fully_captured_below=threshold.scheduled)

    if isempty(ci_builds) && isempty(builds) && isempty(scheduled_builds) &&
       threshold.master == 0 && threshold.scheduled == 0 && threshold.ci == 0
        error("No builds fetched and no existing data - check your token and permissions")
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

    transaction(db) do
        write_timings!(db, build_rows, job_rows) + write_coverage!(db, coverage)
    end
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
