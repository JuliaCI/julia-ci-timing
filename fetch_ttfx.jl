#!/usr/bin/env julia
# Fetch TTFX benchmark results from the julia-ci pipeline on Buildkite.
#
# The TTFX job (JuliaCI/julia-buildkite, utilities/ttfx/) measures every master build on
# the Julia-TTFX-Snippets tasks: per task, precompile time of its packages from a cleared
# cache, then cold load and run time of the task script, each measured in ABBA blocks.
# The job uploads ttfx/results.json (one record per task and block) and
# ttfx/results-meta.json (the build, machine and settings) as artifacts. This script pulls
# both for every finished TTFX job it has not seen and keeps one row per job in
# data/ttfx_summary.json.gz, with the minimum over blocks of each metric per task. The
# job repeats each task script with the GC disabled as well; those give the load, run
# and warm metrics a `_gcoff` counterpart (nothing for jobs from before it did).

using HTTP
using JSON3
using Dates

include(joinpath(@__DIR__, "db", "Store.jl"))
using .Store
using SQLite, DBInterface

const BUILDKITE_ORG = "julialang"
const CI_PIPELINE = "julia-ci"
const BRANCH = "master"
const API_BASE = "https://api.buildkite.com/v2"
# Job label is ":macos: TTFX <triplet>" (pipelines/main/misc/ttfx/ttfx_macos.yml); the
# triplet keeps the group's "Launch TTFX benchmark jobs" step from matching
const TTFX_JOB = r"\bTTFX\s+([a-z0-9_]+-[a-z0-9_-]+)$"
const FINISHED_STATES = ("passed", "failed", "timed_out")
# Metric order in each task's array; the frontend indexes by this. A metric added
# later leaves earlier rows' arrays short: the newest REFETCH_BUILDS such rows are
# fetched again in case the job already recorded it, the rest are padded.
const METRICS = ("precompile", "load", "run", "warm", "load_gcoff", "run_gcoff", "warm_gcoff")
const REFETCH_BUILDS = 30

function get_token()
    token = get(ENV, "BUILDKITE_API_TOKEN", nothing)
    if token === nothing
        token_file = joinpath(homedir(), ".buildkite_token")
        isfile(token_file) && (token = strip(read(token_file, String)))
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
    isempty(params) || (url *= "?" * join(["$k=$v" for (k, v) in params], "&"))
    resp = http_get_retry(url, ["Authorization" => "Bearer $token"])
    if resp.status != 200
        @warn "API request failed" url resp.status String(resp.body)
        return nothing
    end
    return JSON3.read(resp.body)
end

# The artifact download endpoint answers with a redirect to a signed storage URL; follow
# it by hand so the API token is not sent along to the storage host.
function download_artifact(download_url; token=get_token())
    resp = http_get_retry(download_url, ["Authorization" => "Bearer $token"]; redirect=false)
    if resp.status in (301, 302, 303, 307, 308)
        resp = http_get_retry(HTTP.header(resp, "Location"))
    end
    if resp.status != 200
        @warn "Artifact download failed" download_url resp.status
        return nothing
    end
    return resp.body
end

function parse_datetime(s::AbstractString)
    return DateTime(s[1:19], dateformat"yyyy-mm-ddTHH:MM:SS")
end

# results.json records for one arm, reduced to the minimum over blocks of each metric.
# Cold numbers are the first repeat; "warm" is the best of the later repeats' totals,
# matching ttfx_compare.jl in julia-buildkite. A task that never produced a sample is
# listed under `failed` with its first error instead.
function summarize_records(records, arm)
    bytask = Dict{String,Vector{Any}}()
    for r in records
        String(get(r, :arm, "")) == arm || continue
        name = String(r.package) * "/" * String(r.task)
        push!(get!(bytask, name, Any[]), r)
    end
    tasks = Dict{String,Any}()
    failed = Dict{String,String}()
    nanmin(v) = isempty(v) ? nothing : minimum(v)
    for (name, recs) in bytask
        ok = filter(r -> get(r, :status, "") == "ok", recs)
        if isempty(ok)
            err = something(get(recs[1], :error, nothing), "unknown error")
            failed[name] = first(String(err), 200)
            continue
        end
        precompile = nanmin([Float64(r.precompile_time) for r in ok if get(r, :precompile_time, nothing) !== nothing])
        load = nanmin([Float64(r.load_times[1]) for r in ok if !isempty(r.load_times)])
        run = nanmin([Float64(r.run_times[1]) for r in ok if !isempty(r.run_times)])
        warm = nanmin([minimum(Float64.(r.total_times[2:end])) for r in ok if length(r.total_times) >= 2])
        # The GC-off repeats are optional per record: absent before the driver made
        # them, empty when they failed (`error_gcoff`), which leaves `status` alone
        gcoff(r, key) = get(r, key, Any[])
        load_gcoff = nanmin([Float64(gcoff(r, :load_times_gcoff)[1]) for r in ok if !isempty(gcoff(r, :load_times_gcoff))])
        run_gcoff = nanmin([Float64(gcoff(r, :run_times_gcoff)[1]) for r in ok if !isempty(gcoff(r, :run_times_gcoff))])
        warm_gcoff = nanmin([minimum(Float64.(gcoff(r, :total_times_gcoff)[2:end])) for r in ok if length(gcoff(r, :total_times_gcoff)) >= 2])
        round3(x) = x === nothing ? nothing : round(x; digits=3)
        tasks[name] = Any[round3(precompile), round3(load), round3(run), round3(warm),
                          round3(load_gcoff), round3(run_gcoff), round3(warm_gcoff)]
    end
    return tasks, failed
end

function build_row(build, job, results, meta)
    arms = meta === nothing ? nothing : get(meta, :arms, nothing)
    order = meta === nothing ? [] : get(meta, :arm_order, [])
    arm = "head" in String.(order) || (arms !== nothing && haskey(arms, :head)) ? "head" :
          isempty(order) ? "head" : String(order[end])
    head = arms === nothing ? nothing : get(arms, Symbol(arm), nothing)
    tasks, failed = results === nothing ? (Dict{String,Any}(), Dict{String,String}()) :
                    summarize_records(results, arm)

    name = String(job.name)
    m = match(TTFX_JOB, name)
    triplet = m === nothing ? "" : String(m.captures[1])
    raw_message = something(get(build, :message, ""), "")
    message = first(split(String(raw_message), '\n'))
    message = length(message) > 80 ? first(message, 77) * "..." : message
    commit = head !== nothing && haskey(head, :commit) ? String(head.commit) : String(build.commit)
    agent = get(job, :agent, nothing)
    settings = meta === nothing ? nothing : get(meta, :settings, nothing)
    system = meta === nothing ? nothing : get(meta, :system, nothing)
    snippets = meta === nothing ? nothing : get(meta, :snippets, nothing)

    return Dict{String,Any}(
        "build" => build.number,
        "job_id" => String(job.id),
        "triplet" => triplet,
        "state" => String(get(job, :state, "unknown")),
        "date" => Dates.format(parse_datetime(String(build.created_at)), dateformat"yyyy-mm-dd HH:MM"),
        "commit" => commit,
        "version" => head !== nothing ? String(get(head, :version, "")) : "",
        "message" => message,
        "agent" => agent === nothing ? "" : String(get(agent, :hostname, "")),
        "cpu" => system === nothing ? "" : String(get(system, :cpu, "")),
        "snippets" => snippets === nothing ? "" : String(get(snippets, :commit, "")),
        "blocks" => settings === nothing ? nothing : get(settings, :blocks, nothing),
        "n_tasks" => settings === nothing ? length(tasks) + length(failed) : get(settings, :n_tasks, nothing),
        "tasks" => tasks,
        "failed" => failed,
        # Database-only extras, not part of the exported row
        "_arm" => arm,
        "_arms" => arms,
        "_job" => job,
        "_results" => results,
        "_meta" => meta,
    )
end

# (results, meta) for a job, each nothing when the job uploaded no such
# artifact; nothing altogether when the listing or a download failed, so the
# caller leaves the job for the next run instead of recording an empty row.
function fetch_job_artifacts(build, job)
    artifacts = api_get("organizations/$BUILDKITE_ORG/pipelines/$CI_PIPELINE/builds/$(build.number)/jobs/$(job.id)/artifacts")
    artifacts === nothing && return nothing
    function get_json(path)
        i = findfirst(a -> String(get(a, :path, "")) == path && String(get(a, :state, "")) == "finished", artifacts)
        i === nothing && return missing
        body = download_artifact(String(artifacts[i].download_url))
        body === nothing && return nothing
        return JSON3.read(body)
    end
    results = get_json("ttfx/results.json")
    results === nothing && return nothing
    meta = get_json("ttfx/results-meta.json")
    meta === nothing && return nothing
    return (results === missing ? nothing : results, meta === missing ? nothing : meta)
end

# New rows for finished TTFX jobs not in `known`. Builds are listed newest first; stop
# once a page holds nothing new and is older than everything already known, or, before
# any row exists, once a page has no TTFX job at all (the job only exists from a point on).
function fetch_new_rows(known::Set{String}; per_page=100, max_pages=30)
    rows = Dict{String,Any}[]
    # Everything older than the 50 newest known builds counts as captured, so
    # the pages walked per run do not grow with the history
    known_builds = sort!(unique(parse(Int, first(split(k, ':'))) for k in known); rev=true)
    min_known = isempty(known_builds) ? typemax(Int) : known_builds[min(50, end)]
    seen_any = false
    for page in 1:max_pages
        params = Dict("branch" => BRANCH, "per_page" => per_page, "page" => page)
        builds = api_get("organizations/$BUILDKITE_ORG/pipelines/$CI_PIPELINE/builds"; params)
        (builds === nothing || isempty(builds)) && break
        new_in_page = 0
        ttfx_in_page = 0
        oldest = typemax(Int)
        for build in builds
            oldest = min(oldest, build.number)
            for job in get(build, :jobs, [])
                get(job, :type, nothing) == "script" || continue
                name = get(job, :name, nothing)
                (name === nothing || match(TTFX_JOB, String(name)) === nothing) && continue
                ttfx_in_page += 1
                key = "$(build.number):$(job.id)"
                key in known && continue
                String(get(job, :state, "")) in FINISHED_STATES || continue
                @info "Fetching TTFX results" build=build.number job=String(name) state=String(job.state)
                fetched = fetch_job_artifacts(build, job)
                if fetched === nothing
                    @warn "Could not fetch the artifacts; the job is retried next run" build=build.number
                    continue
                end
                results, meta = fetched
                if results === nothing
                    @info "No results artifact" build=build.number
                end
                push!(rows, build_row(build, job, results, meta))
                push!(known, key)
                new_in_page += 1
            end
        end
        @info "Fetched page $page" new=new_in_page ttfx_jobs=ttfx_in_page oldest
        seen_any |= ttfx_in_page > 0
        if oldest < min_known && new_in_page == 0
            @info "Reached fully captured region, stopping early"
            break
        end
        if min_known == typemax(Int) && seen_any && ttfx_in_page == 0
            @info "No TTFX jobs on this page, stopping"
            break
        end
    end
    return rows
end

row_key(r) = "$(r["build"]):$(r["job_id"])"

at(x) = x === nothing ? missing : Store.iso(Store.parse_upstream(String(x)))
str_or_missing(x) = x === nothing ? missing : String(x)
jsonstr(x) = x === nothing ? missing : JSON3.write(x)

const JOB_COLS = ["pipeline", "build", "triplet", "state", "build_created_at", "commit_sha", "version", "message", "agent", "cpu",
                  "snippets", "blocks", "n_tasks", "n_metrics", "selected_arm", "started_at", "finished_at", "web_url", "has_samples"]

# Store one row and its children, replacing whatever the job had before.
function write_row!(db, r, seq, stmts)
    uuid = r["job_id"]
    job = r["_job"]
    upsert!(stmts.job, (uuid, CI_PIPELINE, r["build"], r["triplet"], r["state"], legacy_minute_to_iso(r["date"]), r["commit"],
                        r["version"], r["message"], r["agent"], r["cpu"], r["snippets"], something(r["blocks"], missing),
                        something(r["n_tasks"], missing), length(METRICS), r["_arm"], at(get(job, :started_at, nothing)),
                        at(get(job, :finished_at, nothing)), str_or_missing(get(job, :web_url, nothing)),
                        r["_results"] === nothing ? 0 : 1, seq))
    for t in ("ttfx_results", "ttfx_failures", "ttfx_arms", "ttfx_samples")
        DBInterface.execute(db, "DELETE FROM $t WHERE job_uuid = ?", (uuid,))
    end
    for (task, vals) in r["tasks"]
        DBInterface.execute(stmts.result, (uuid, task, (something(v, missing) for v in vals)...))
    end
    for (task, err) in r["failed"]
        DBInterface.execute(stmts.failure, (uuid, task, err))
    end
    if r["_arms"] !== nothing
        for (arm, info) in pairs(r["_arms"])
            DBInterface.execute(stmts.arm, (uuid, String(arm), str_or_missing(get(info, :commit, nothing)), str_or_missing(get(info, :version, nothing))))
        end
    end
    if r["_results"] !== nothing
        for (i, rec) in enumerate(r["_results"])
            DBInterface.execute(stmts.sample, (uuid, i, String(get(rec, :package, "")) * "/" * String(get(rec, :task, "")),
                String(get(rec, :arm, "")), get(rec, :block, nothing) === nothing ? missing : Int(rec.block),
                str_or_missing(get(rec, :status, nothing)), str_or_missing(get(rec, :error, nothing)), str_or_missing(get(rec, :error_gcoff, nothing)),
                get(rec, :precompile_time, nothing) === nothing ? missing : Float64(rec.precompile_time),
                jsonstr(get(rec, :load_times, nothing)), jsonstr(get(rec, :run_times, nothing)), jsonstr(get(rec, :total_times, nothing)),
                jsonstr(get(rec, :load_times_gcoff, nothing)), jsonstr(get(rec, :run_times_gcoff, nothing)), jsonstr(get(rec, :total_times_gcoff, nothing))))
        end
    end
    # The artifacts expire on Buildkite; keep what was parsed
    DBInterface.execute(stmts.raw, (uuid, iso_now(), r["_results"] === nothing ? missing : compress_zst(JSON3.write(r["_results"])),
                                    r["_meta"] === nothing ? missing : compress_zst(JSON3.write(r["_meta"]))))
end

function write_rows!(db, rows)
    seq = next_seq!(db)
    stmts = (
        job = upsert_stmt(db, "ttfx_jobs", ["job_uuid"], JOB_COLS),
        result = DBInterface.prepare(db, "INSERT INTO ttfx_results (job_uuid, task, $(join(METRICS, ", "))) VALUES (?, ?, $(join(fill("?", length(METRICS)), ", ")))"),
        failure = DBInterface.prepare(db, "INSERT INTO ttfx_failures (job_uuid, task, error) VALUES (?, ?, ?)"),
        arm = DBInterface.prepare(db, "INSERT INTO ttfx_arms (job_uuid, arm, commit_sha, version) VALUES (?, ?, ?, ?)"),
        sample = DBInterface.prepare(db, "INSERT INTO ttfx_samples (job_uuid, seq, task, arm, block, status, error, error_gcoff, precompile_s, " *
                                         "load_s, run_s, total_s, load_gcoff_s, run_gcoff_s, total_gcoff_s) VALUES ($(join(fill("?", 15), ", ")))"),
        raw = DBInterface.prepare(db, "INSERT OR REPLACE INTO raw_ttfx (job_uuid, fetched_at, results_zst, meta_zst) VALUES (?, ?, ?, ?)"))
    for r in rows
        write_row!(db, r, seq, stmts)
    end
    return length(rows)
end

function main(args=ARGS)
    db = open_db(Store.db_path(args); create=false)
    existing = SQLite.Tables.rowtable(DBInterface.execute(db, "SELECT build, job_uuid, n_metrics FROM ttfx_jobs"))
    # Rows short of a metric: the recent ones are fetched again, the rest
    # padded (their metric arrays already read as nulls; only the length
    # marker changes)
    builds_desc = sort!(unique(Int(r.build) for r in existing); rev=true)
    refetch_from = isempty(builds_desc) ? 0 : builds_desc[min(REFETCH_BUILDS, end)]
    refetch = Set("$(r.build):$(r.job_uuid)" for r in existing if r.n_metrics < length(METRICS) && r.build >= refetch_from)
    isempty(refetch) || @info "Rows fetched again for the metrics they lack" count=length(refetch)
    known = Set("$(r.build):$(r.job_uuid)" for r in existing if !("$(r.build):$(r.job_uuid)" in refetch))

    new_rows = fetch_new_rows(known)
    @info "New TTFX rows" count=length(new_rows)
    if isempty(new_rows) && isempty(existing)
        @error "No TTFX results found and no existing data - check the token and that julia-ci runs the TTFX job"
        return 1
    end

    source_run(db, "ttfx") do
        transaction(db) do
            seq = next_seq!(db)
            DBInterface.execute(db, "UPDATE ttfx_jobs SET n_metrics = ?, change_seq = ? WHERE n_metrics < ? AND build < ?",
                                (length(METRICS), seq, length(METRICS), refetch_from))
            write_rows!(db, new_rows)
        end
    end
    close(db)
    return 0
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
