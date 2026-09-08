#!/usr/bin/env julia
# Fetch TTFX benchmark results from the julia-ci pipeline on Buildkite.
#
# The TTFX job (JuliaCI/julia-buildkite, utilities/ttfx/) measures every master build on
# the Julia-TTFX-Snippets tasks: per task, precompile time of its packages from a cleared
# cache, then cold load and run time of the task script, each measured in ABBA blocks.
# The job uploads ttfx/results.json (one record per task and block) and
# ttfx/results-meta.json (the build, machine and settings) as artifacts. This script pulls
# both for every finished TTFX job it has not seen and keeps one row per job in
# data/ttfx_summary.json.gz, with the minimum over blocks of each metric per task.

using HTTP
using JSON3
using Dates
using CodecZlib: GzipCompressor, GzipDecompressor

const BUILDKITE_ORG = "julialang"
const CI_PIPELINE = "julia-ci"
const BRANCH = "master"
const API_BASE = "https://api.buildkite.com/v2"
const OUTPUT = joinpath("data", "ttfx_summary.json.gz")
# Job label is ":macos: TTFX <triplet>" (pipelines/main/misc/ttfx/ttfx_macos.yml)
const TTFX_JOB = r"\bTTFX\s+(\S+)"
const FINISHED_STATES = ("passed", "failed", "timed_out")
# Metric order in each task's array; the frontend indexes by this
const METRICS = ("precompile", "load", "run", "warm")

function get_token()
    token = get(ENV, "BUILDKITE_API_TOKEN", nothing)
    if token === nothing
        token_file = joinpath(homedir(), ".buildkite_token")
        isfile(token_file) && (token = strip(read(token_file, String)))
    end
    token === nothing && error("Set BUILDKITE_API_TOKEN env var or create ~/.buildkite_token")
    return token
end

function api_get(endpoint; token=get_token(), params=Dict())
    url = "$API_BASE/$endpoint"
    isempty(params) || (url *= "?" * join(["$k=$v" for (k, v) in params], "&"))
    resp = HTTP.get(url, ["Authorization" => "Bearer $token"]; status_exception=false, retry=true, retries=3)
    if resp.status != 200
        @warn "API request failed" url resp.status String(resp.body)
        return nothing
    end
    return JSON3.read(resp.body)
end

# The artifact download endpoint answers with a redirect to a signed storage URL; follow
# it by hand so the API token is not sent along to the storage host.
function download_artifact(download_url; token=get_token())
    resp = HTTP.get(download_url, ["Authorization" => "Bearer $token"];
                    status_exception=false, redirect=false, retry=true, retries=3)
    if resp.status in (301, 302, 303, 307, 308)
        resp = HTTP.get(HTTP.header(resp, "Location"); status_exception=false, retry=true, retries=3)
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

function load_existing()
    try
        if isfile(OUTPUT)
            data = JSON3.read(transcode(GzipDecompressor, read(OUTPUT)))
            rows = [Dict{String,Any}(String(k) => v for (k, v) in pairs(r)) for r in get(data, :builds, [])]
            @info "Loaded existing TTFX summary" rows=length(rows)
            return rows
        end
    catch e
        @warn "Failed to load existing summary, starting fresh" error=e
    end
    return Dict{String,Any}[]
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
        round3(x) = x === nothing ? nothing : round(x; digits=3)
        tasks[name] = Any[round3(precompile), round3(load), round3(run), round3(warm)]
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
    )
end

function fetch_job_artifacts(build, job)
    artifacts = api_get("organizations/$BUILDKITE_ORG/pipelines/$CI_PIPELINE/builds/$(build.number)/jobs/$(job.id)/artifacts")
    artifacts === nothing && return nothing, nothing
    function get_json(path)
        i = findfirst(a -> String(get(a, :path, "")) == path && String(get(a, :state, "")) == "finished", artifacts)
        i === nothing && return nothing
        body = download_artifact(String(artifacts[i].download_url))
        body === nothing && return nothing
        return JSON3.read(body)
    end
    return get_json("ttfx/results.json"), get_json("ttfx/results-meta.json")
end

# New rows for finished TTFX jobs not in `known`. Builds are listed newest first; stop
# once a page holds nothing new and is older than everything already known, or, before
# any row exists, once a page has no TTFX job at all (the job only exists from a point on).
function fetch_new_rows(known::Set{String}; per_page=100, max_pages=30)
    rows = Dict{String,Any}[]
    min_known = isempty(known) ? typemax(Int) : minimum(parse(Int, first(split(k, ':'))) for k in known)
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
                results, meta = fetch_job_artifacts(build, job)
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

function write_summary(rows; output=OUTPUT)
    sort!(rows; by=r -> (r["date"], r["build"]))
    task_names = sort!(unique(vcat([collect(keys(r["tasks"])) for r in rows]...,
                                   [collect(keys(r["failed"])) for r in rows]...)))
    summary = Dict{String,Any}(
        "generated_at" => Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SSZ"),
        "pipeline" => CI_PIPELINE,
        "branch" => BRANCH,
        "metrics" => collect(METRICS),
        "tasks" => task_names,
        "builds" => rows,
    )
    mkpath(dirname(output))
    write(output, transcode(GzipCompressor, Vector{UInt8}(JSON3.write(summary))))
    @info "Wrote summary" file=output rows=length(rows) tasks=length(task_names)
end

function main()
    mkpath("data")
    existing = load_existing()
    known = Set("$(r["build"]):$(r["job_id"])" for r in existing)

    new_rows = fetch_new_rows(known)
    @info "New TTFX rows" count=length(new_rows)
    if isempty(new_rows) && isfile(OUTPUT)
        @info "No changes to data, skipping write" file=OUTPUT
        return 0
    end
    if isempty(new_rows) && isempty(existing)
        @error "No TTFX results found and no existing data - check the token and that julia-ci runs the TTFX job"
        return 1
    end

    write_summary(vcat(existing, new_rows))
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
