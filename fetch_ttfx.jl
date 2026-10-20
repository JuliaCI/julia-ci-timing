#!/usr/bin/env julia
# Fetch TTFX benchmark results from the julia-ci pipeline on Buildkite.
#
# The TTFX job (JuliaCI/julia-buildkite, utilities/ttfx/) measures every master build on
# the Julia-TTFX-Snippets tasks: per task, precompile time of its packages from a cleared
# cache, then cold load and run time of the task script, each measured in ABBA blocks.
# The job uploads ttfx/results.json (one record per task and block) and
# ttfx/results-meta.json (the build, machine and settings) as artifacts. This script pulls
# both for every finished TTFX job it has not seen and keeps one row per job in the
# database (ttfx_jobs and its children), with the minimum over blocks of each metric per
# task; db/export.jl renders data/ttfx_summary.json.gz from them. The
# job repeats each task script with the GC disabled as well; those give the load, run
# and warm metrics a `_gcoff` counterpart (nothing for jobs from before it did).
# A weekly job measures the newest stable release on the same tasks and machines, as a
# reference; its rows have kind 'release' and the release's version and commit. A second
# weekly job does the same for the newest patch release of the LTS series (kind 'lts'),
# and a third for the nightly of the next release's branch (kind 'branch_nightly').
# The nightly schedule's optimized build (PGO and ThinLTO, JULIA_CI_BUILD_MODE=opt) is
# measured too; its rows have kind 'opt'. Once a release branch has commits of its own,
# julia-ci measures each of its builds as it does master's; those rows have kind
# 'release_branch'.
# Jobs whose driver logs invalidations add, per task, how many MethodInstances the task
# script invalidated, and the top causes (ttfx_invalidation_causes). Separately, every
# job's ttfx/trace-compile.tar.gz is parsed for the methods compiled again because an
# invalidation dropped their code (ttfx_traces, ttfx_recompiles; see refresh_traces!).
# It also keeps the latest comparison of each open pull request in ttfx_prs (see below).

using HTTP
using JSON3
using Dates
using CodecZlib: GzipDecompressor
using Tar

include(joinpath(@__DIR__, "db", "Store.jl"))
include(joinpath(@__DIR__, "db", "Fetch.jl"))
using .Store
using SQLite, DBInterface

const CI_PIPELINE = "julia-ci"
# Job label is ":macos: TTFX <triplet>" (pipelines/main/misc/ttfx/ttfx_macos.yml),
# ":macos: TTFX release <triplet>", ":macos: TTFX lts <triplet>" and
# ":macos: TTFX branch nightly <triplet>" for the weekly references, or
# ":macos: TTFX opt <triplet>" for the nightly optimized build; the triplet keeps the
# group's "Launch TTFX benchmark jobs" step from matching
const TTFX_JOB = r"\bTTFX\s+(?:(release|lts|opt|branch nightly)\s+)?([a-z0-9_]+-[a-z0-9_-]+)$"
const FINISHED_STATES = ("passed", "failed", "timed_out")
# Metric order in each task's array; the frontend indexes by this. A metric added
# later leaves earlier rows' arrays short: the newest REFETCH_BUILDS such rows are
# fetched again in case the job already recorded it, the rest are padded.
const METRICS = ("precompile", "load", "run", "warm", "load_gcoff", "run_gcoff", "warm_gcoff", "invalidated",
                 "load_stdlibs", "precompile_stdlibs")
const REFETCH_BUILDS = 30

# A record's `invalidations` (block 1, from the job's untimed invalidation run): the
# MethodInstances invalidated over the load and run phases, split by how, and the top
# causes of each kind as (phase, kind, rank, cause, n). Nothing for a record without it.
function record_invalidations(r)
    inv = get(r, :invalidations, nothing)
    inv === nothing && return nothing
    total = by_definition = rejected = 0
    causes = Any[]
    for phase in ("load", "run")
        p = get(inv, Symbol(phase), nothing)
        p === nothing && continue
        total += Int(p.invalidated)
        by_definition += Int(p.by_definition)
        rejected += Int(p.rejected_at_load)
        for (kind, key) in (("definition", :top_definitions), ("rejected", :top_rejected))
            for (rank, (cause, n)) in enumerate(get(p, key, []))
                push!(causes, (phase, kind, rank, String(cause), Int(n)))
            end
        end
    end
    return (; invalidated=total, by_definition, rejected, causes)
end

# results.json records for one arm, reduced to the minimum over blocks of each metric.
# Cold numbers are the first repeat; "warm" is the best of the later repeats' totals,
# matching ttfx_compare.jl in julia-buildkite. A task that never produced a sample is
# listed under `failed` with its first error instead. `invalidations` holds, per task,
# record_invalidations of the record that has them.
function summarize_records(records, arm)
    bytask = Dict{String,Vector{Any}}()
    for r in records
        String(get(r, :arm, "")) == arm || continue
        name = String(r.package) * "/" * String(r.task)
        push!(get!(bytask, name, Any[]), r)
    end
    tasks = Dict{String,Any}()
    failed = Dict{String,String}()
    invalidations = Dict{String,Any}()
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
        # So is the run in a copy of the project with every stdlib added and loaded
        # first (`error_stdlibs`), and the precompile of that copy after the task's own
        load_stdlibs = nanmin([Float64(gcoff(r, :load_times_stdlibs)[1]) for r in ok if !isempty(gcoff(r, :load_times_stdlibs))])
        precompile_stdlibs = nanmin([Float64(r.precompile_time_stdlibs) for r in ok if get(r, :precompile_time_stdlibs, nothing) !== nothing])
        round3(x) = x === nothing ? nothing : round(x; digits=3)
        k = findfirst(r -> get(r, :invalidations, nothing) !== nothing, ok)
        inv = k === nothing ? nothing : record_invalidations(ok[k])
        inv === nothing || (invalidations[name] = inv)
        tasks[name] = Any[round3(precompile), round3(load), round3(run), round3(warm),
                          round3(load_gcoff), round3(run_gcoff), round3(warm_gcoff),
                          inv === nothing ? nothing : inv.invalidated,
                          round3(load_stdlibs), round3(precompile_stdlibs)]
    end
    return tasks, failed, invalidations
end

function build_row(build, job, results, meta)
    arms = meta === nothing ? nothing : get(meta, :arms, nothing)
    order = meta === nothing ? [] : get(meta, :arm_order, [])
    arm = "head" in String.(order) || (arms !== nothing && haskey(arms, :head)) ? "head" :
          isempty(order) ? "head" : String(order[end])
    head = arms === nothing ? nothing : get(arms, Symbol(arm), nothing)
    tasks, failed, invalidations = results === nothing ? (Dict{String,Any}(), Dict{String,String}(), Dict{String,Any}()) :
                                   summarize_records(results, arm)

    name = String(job.name)
    m = match(TTFX_JOB, name)
    triplet = m === nothing ? "" : String(m.captures[2])
    # An optimized build's triplet ends in `opt` (aarch64-apple-darwinopt), whatever the label says
    kind = m === nothing ? "master" : m.captures[1] !== nothing ? replace(String(m.captures[1]), ' ' => '_') :
           endswith(triplet, "opt") ? "opt" : "master"
    # The regular TTFX job of a release branch's own build
    kind == "master" && String(something(get(build, :branch, "master"), "master")) != "master" && (kind = "release_branch")
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
        "kind" => kind,
        "state" => String(get(job, :state, "unknown")),
        "created_at" => Store.iso(Store.parse_upstream(String(build.created_at))),
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
        "_invalidations" => invalidations,
    )
end

# The parsed artifacts at `paths` for a job (by default results and meta), each nothing
# when the job uploaded no such artifact; nothing altogether when the listing or a
# download failed, so the caller leaves the job for the next run instead of recording
# an empty row.
function fetch_job_artifacts(build, job; pipeline=CI_PIPELINE, paths=("ttfx/results.json", "ttfx/results-meta.json"))
    artifacts = buildkite_get("organizations/$BUILDKITE_ORG/pipelines/$pipeline/builds/$(build.number)/jobs/$(job.id)/artifacts")
    artifacts === nothing && return nothing
    function get_json(path)
        i = findfirst(a -> String(get(a, :path, "")) == path && String(get(a, :state, "")) == "finished", artifacts)
        i === nothing && return missing
        body = download_artifact(String(artifacts[i].download_url))
        body === nothing && return nothing
        return JSON3.read(body)
    end
    out = Any[]
    for path in paths
        v = get_json(path)
        v === nothing && return nothing
        push!(out, v === missing ? nothing : v)
    end
    return Tuple(out)
end

# New rows for finished TTFX jobs not in `known`. Builds are listed newest first; stop
# once a page holds nothing new and is older than everything already known, or, before
# any row exists, once a page has no TTFX job at all (the job only exists from a point on).
# `refetch` names the known jobs being fetched again for the metrics their row lacks;
# one whose artifacts have expired keeps its row (returned in `expired`, so the caller
# pads it) instead of being rewritten empty. A failed listing throws: the run is then
# recorded as failed rather than as one that found nothing.
function fetch_new_rows(known::Set{String}; refetch::Set{String}=Set{String}(), max_pages=30)
    rows = Dict{String,Any}[]
    expired = String[]
    # Everything older than the 50 newest known builds counts as captured, so
    # the pages walked per run do not grow with the history
    known_builds = sort!(unique(parse(Int, first(split(k, ':'))) for k in known); rev=true)
    min_known = isempty(known_builds) ? typemax(Int) : known_builds[min(50, end)]
    seen_any = false
    # Every branch: master, and the release branches once they have commits of their own
    buildkite_pages("organizations/$BUILDKITE_ORG/pipelines/$CI_PIPELINE/builds"; max_pages) do builds, page
        new_in_page = 0
        ttfx_in_page = 0
        oldest = typemax(Int)
        for build in builds
            oldest = min(oldest, build.number)
            branch = String(something(get(build, :branch, "master"), "master"))
            (branch == "master" || startswith(branch, "release-")) || continue
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
                if results === nothing && key in refetch
                    @warn "The artifacts are gone; the row keeps what it has" build=build.number
                    push!(expired, String(job.id))
                    push!(known, key)
                    continue
                end
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
            return :stop
        end
        if min_known == typemax(Int) && seen_any && ttfx_in_page == 0
            @info "No TTFX jobs on this page, stopping"
            return :stop
        end
    end
    return rows, expired
end

row_key(r) = "$(r["build"]):$(r["job_id"])"

at(x) = x === nothing ? missing : Store.iso(Store.parse_upstream(String(x)))
str_or_missing(x) = x === nothing ? missing : String(x)
jsonstr(x) = x === nothing ? missing : JSON3.write(x)

const JOB_COLS = ["pipeline", "build", "triplet", "kind", "state", "build_created_at", "commit_sha", "version", "message", "agent", "cpu",
                  "snippets", "blocks", "n_tasks", "n_metrics", "selected_arm", "started_at", "finished_at", "web_url", "has_samples"]

# Store one row and its children, replacing whatever the job had before.
function write_row!(db, r, seq, stmts)
    uuid = r["job_id"]
    job = r["_job"]
    upsert!(stmts.job, (uuid, CI_PIPELINE, r["build"], r["triplet"], r["kind"], r["state"], r["created_at"], r["commit"],
                        r["version"], r["message"], r["agent"], r["cpu"], r["snippets"], something(r["blocks"], missing),
                        something(r["n_tasks"], missing), length(METRICS), r["_arm"], at(get(job, :started_at, nothing)),
                        at(get(job, :finished_at, nothing)), str_or_missing(get(job, :web_url, nothing)),
                        r["_results"] === nothing ? 0 : 1, seq))
    for t in ("ttfx_results", "ttfx_failures", "ttfx_arms", "ttfx_samples", "ttfx_invalidation_causes")
        DBInterface.execute(db, "DELETE FROM $t WHERE job_uuid = ?", (uuid,))
    end
    for (task, vals) in r["tasks"]
        inv = get(r["_invalidations"], task, nothing)
        DBInterface.execute(stmts.result, (uuid, task, (something(v, missing) for v in vals)...,
                                           inv === nothing ? missing : inv.by_definition, inv === nothing ? missing : inv.rejected))
        inv === nothing && continue
        for (phase, kind, rank, cause, n) in inv.causes
            DBInterface.execute(stmts.cause, (uuid, task, phase, kind, rank, cause, n))
        end
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
                jsonstr(get(rec, :load_times_gcoff, nothing)), jsonstr(get(rec, :run_times_gcoff, nothing)), jsonstr(get(rec, :total_times_gcoff, nothing)),
                str_or_missing(get(rec, :error_stdlibs, nothing)),
                get(rec, :precompile_time_stdlibs, nothing) === nothing ? missing : Float64(rec.precompile_time_stdlibs),
                jsonstr(get(rec, :load_times_stdlibs, nothing)), jsonstr(get(rec, :run_times_stdlibs, nothing))))
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
        result = DBInterface.prepare(db, "INSERT INTO ttfx_results (job_uuid, task, $(join(METRICS, ", ")), invalidated_by_definition, invalidated_rejected) " *
                                         "VALUES (?, ?, $(join(fill("?", length(METRICS) + 2), ", ")))"),
        cause = DBInterface.prepare(db, "INSERT INTO ttfx_invalidation_causes (job_uuid, task, phase, kind, rank, cause, n) VALUES (?, ?, ?, ?, ?, ?, ?)"),
        failure = DBInterface.prepare(db, "INSERT INTO ttfx_failures (job_uuid, task, error) VALUES (?, ?, ?)"),
        arm = DBInterface.prepare(db, "INSERT INTO ttfx_arms (job_uuid, arm, commit_sha, version) VALUES (?, ?, ?, ?)"),
        sample = DBInterface.prepare(db, "INSERT INTO ttfx_samples (job_uuid, seq, task, arm, block, status, error, error_gcoff, precompile_s, " *
                                         "load_s, run_s, total_s, load_gcoff_s, run_gcoff_s, total_gcoff_s, error_stdlibs, precompile_stdlibs_s, " *
                                         "load_stdlibs_s, run_stdlibs_s) VALUES ($(join(fill("?", 19), ", ")))"),
        raw = DBInterface.prepare(db, "INSERT OR REPLACE INTO raw_ttfx (job_uuid, fetched_at, results_zst, meta_zst) VALUES (?, ?, ?, ?)"))
    for r in rows
        write_row!(db, r, seq, stmts)
    end
    return length(rows)
end

# --- traces ------------------------------------------------------------------
#
# The job runs each task script once more per arm with --trace-compile
# --trace-compile-timing and uploads the logs as ttfx/trace-compile.tar.gz
# (trace/<Package>-<Task>-<arm>.log). A statement the log marks "# recompile" is a
# method compiled again because an invalidation had dropped its earlier code. Every
# job is looked at once, newest first and TRACE_JOBS_PER_RUN per run, so the history
# whose artifacts have not expired is filled in over a few runs.

const TRACE_ARTIFACT = "ttfx/trace-compile.tar.gz"
const TRACE_JOBS_PER_RUN = 60
const TRACE_STATEMENT_MAX = 2000

# One trace log: its precompile statements, and the recompiled ones as (ms, statement)
# with the timing comment and the marker stripped
function parse_trace(text::AbstractString)
    statements = 0
    recompiles = Tuple{Union{Float64,Missing},String}[]
    for line in eachline(IOBuffer(text))
        occursin("precompile(", line) || continue
        statements += 1
        endswith(rstrip(line), "# recompile") || continue
        m = match(r"^#=\s*([\d.]+)\s*ms\s*=#\s*", line)
        ms = m === nothing ? missing : parse(Float64, m.captures[1])
        stmt = strip(replace(m === nothing ? line : line[length(m.match)+1:end], r"\s*# recompile\s*$" => ""))
        push!(recompiles, (ms, first(stmt, TRACE_STATEMENT_MAX)))
    end
    return (; statements, recompiles)
end

# The logs of one arm in a trace tarball, by task ("Package/Task"). A package name
# has no '-', so the first one ends it.
function parse_trace_tarball(bytes, arm)
    dir = mktempdir()
    try
        Tar.extract(IOBuffer(transcode(GzipDecompressor, bytes)), dir)
        out = Dict{String,Any}()
        tracedir = joinpath(dir, "trace")
        isdir(tracedir) || return out
        suffix = "-$arm.log"
        for f in readdir(tracedir)
            endswith(f, suffix) || continue
            stem = f[1:end-length(suffix)]
            i = findfirst('-', stem)
            i === nothing && continue
            out[stem[1:i-1] * "/" * stem[i+1:end]] = parse_trace(read(joinpath(tracedir, f), String))
        end
        return out
    finally
        rm(dir; recursive=true, force=true)
    end
end

# Parse the traces of jobs not looked at yet. A job without the artifact (it predates
# the trace runs, or Buildkite has expired it) is marked 'none'; one whose listing or
# download fails is left for the next run.
function refresh_traces!(db; limit=TRACE_JOBS_PER_RUN)
    jobs = query(db, "SELECT job_uuid, pipeline, build, selected_arm FROM ttfx_jobs WHERE trace_state IS NULL " *
                     "ORDER BY build_created_at DESC LIMIT ?", (limit,))
    isempty(jobs) && return 0
    @info "Looking at TTFX traces" jobs=length(jobs)
    parsed = Any[]
    for j in jobs
        uuid = String(j.job_uuid)
        artifacts = buildkite_get("organizations/$BUILDKITE_ORG/pipelines/$(j.pipeline)/builds/$(j.build)/jobs/$uuid/artifacts")
        artifacts === nothing && continue
        i = findfirst(a -> String(get(a, :path, "")) == TRACE_ARTIFACT && String(get(a, :state, "")) == "finished", artifacts)
        if i === nothing
            push!(parsed, (uuid, nothing))
            continue
        end
        body = download_artifact(String(artifacts[i].download_url))
        body === nothing && continue
        tasks = try
            parse_trace_tarball(body, String(coalesce(j.selected_arm, "head")))
        catch e
            @warn "Unreadable trace tarball; marked as none" build=j.build exception=e
            nothing
        end
        push!(parsed, (uuid, tasks))
    end
    transaction(db) do
        seq = next_seq!(db)
        trace = DBInterface.prepare(db, "INSERT INTO ttfx_traces (job_uuid, task, statements, recompiled, recompile_s) VALUES (?, ?, ?, ?, ?)")
        recompile = DBInterface.prepare(db, "INSERT INTO ttfx_recompiles (job_uuid, task, seq, ms, statement) VALUES (?, ?, ?, ?, ?)")
        for (uuid, tasks) in parsed
            for t in ("ttfx_traces", "ttfx_recompiles")
                DBInterface.execute(db, "DELETE FROM $t WHERE job_uuid = ?", (uuid,))
            end
            for (task, tr) in something(tasks, Dict())
                secs = sum((coalesce(ms, 0.0) for (ms, _) in tr.recompiles); init=0.0) / 1000
                DBInterface.execute(trace, (uuid, task, tr.statements, length(tr.recompiles), round(secs; digits=4)))
                for (k, (ms, stmt)) in enumerate(tr.recompiles)
                    DBInterface.execute(recompile, (uuid, task, k, ms, stmt))
                end
            end
            DBInterface.execute(db, "UPDATE ttfx_jobs SET trace_state = ?, change_seq = ? WHERE job_uuid = ?",
                                (tasks === nothing ? "none" : "ok", seq, uuid))
        end
    end
    return length(parsed)
end

# --- pull requests -----------------------------------------------------------
#
# On julia-pr the TTFX job runs when a pull request touches the paths it watches (or has
# its label), measuring the head against the master build of the merge-base, and uploads
# its verdict as ttfx/compare.json. ttfx_prs keeps the latest one of each open pull
# request, for ranking them; nothing older is kept.

const PR_PIPELINE = "julia-pr"
# Builds listed per run: the first fill reaches back a month, later runs only need the
# builds since the last one, with a margin for jobs still running then
const PR_BACKFILL_DAYS = 30
const PR_LOOKBACK_DAYS = 3
const PR_COLS = ["title", "author", "draft", "pr_head_sha", "build", "job_uuid", "job_state", "build_created_at", "finished_at",
                 "web_url", "head_commit", "head_version", "base_commit", "base_version", "blocks", "n_tasks", "verdict",
                 "n_improvements", "n_regressions", "suite", "tasks"]

# The open pull request list costs about a dozen requests of the 60 an hour GitHub allows
# an anonymous address, so it is fetched at most this often and kept in meta between
const PULLS_REFRESH = Hour(2)

# The fields of a pull request used here, to keep the copy in meta small
function pull_summary(p)
    user = get(p, :user, nothing)
    repo = get(p.head, :repo, nothing)
    return Dict("number" => Int(p.number), "state" => String(p.state), "title" => String(something(get(p, :title, ""), "")),
                "user" => user === nothing ? nothing : Dict("login" => String(user.login)), "draft" => get(p, :draft, false) === true,
                "head" => Dict("sha" => String(p.head.sha), "ref" => String(p.head.ref),
                               "repo" => repo === nothing ? nothing : Dict("full_name" => String(get(repo, :full_name, "")))),
                "base" => Dict("ref" => String(p.base.ref)))
end

# The open pull requests by number, when that list was taken, and whether it was taken
# just now (else it is the copy kept in meta, younger than PULLS_REFRESH)
function open_pulls(db)
    at = query(db, "SELECT value FROM meta WHERE key = 'ttfx:open_prs_at'")
    if !isempty(at)
        listed_at = Store.parse_upstream(String(at[1].value))
        list = query(db, "SELECT value FROM meta WHERE key = 'ttfx:open_prs'")
        if now(UTC) - listed_at < PULLS_REFRESH && !isempty(list)
            return Dict{Int,Any}(Int(p.number) => p for p in JSON3.read(String(list[1].value))), listed_at, false
        end
    end
    listed_at = now(UTC)
    return github_open_pulls(), listed_at, true
end

# The list is paged, and a pull request closed meanwhile moves the later
# pages up by one, so an open one can be missing from it. Those of `numbers`
# the list left out are asked about one at a time; the open ones are added.
function confirm_missing!(pulls, numbers)
    for n in numbers
        haskey(pulls, n) && continue
        p = github_pull(n)
        p === nothing && error("looking up pull request $n failed")
        String(p.state) == "open" && (pulls[n] = p)
    end
    return pulls
end

# Finished TTFX jobs of julia-pr builds created since `since`, by pull request number,
# newest first.
function pr_ttfx_jobs(since::DateTime)
    jobs = Dict{Int,Vector{Any}}()
    buildkite_pages("organizations/$BUILDKITE_ORG/pipelines/$PR_PIPELINE/builds", ["created_from" => Store.iso(since)]; max_pages=50) do builds, _
        for build in builds
            pr = get(build, :pull_request, nothing)
            n = pr === nothing ? nothing : tryparse(Int, string(get(pr, :id, "")))
            n === nothing && continue
            for job in get(build, :jobs, [])
                get(job, :type, nothing) == "script" || continue
                name = get(job, :name, nothing)
                m = name === nothing ? nothing : match(TTFX_JOB, String(name))
                # Only the comparison job; a release run would have no verdict to keep
                (m === nothing || m.captures[1] !== nothing) && continue
                String(get(job, :state, "")) in FINISHED_STATES || continue
                push!(get!(jobs, n, Any[]), (build, job))
            end
        end
    end
    return jobs
end

function pr_row(pull, build, job, compare, meta)
    arms = meta === nothing ? nothing : get(meta, :arms, nothing)
    arm(label) = arms === nothing ? nothing : get(arms, Symbol(String(get(compare, label, String(label)))), nothing)
    field(a, key) = a === nothing ? "" : String(something(get(a, key, ""), ""))
    head, base = arm(:head), arm(:base)
    # Only what the verdict rests on; the notes quote whole error messages
    flagged = Any[]
    for (name, t) in pairs(something(get(compare, :tasks, nothing), Dict()))
        imps, regs = get(t, :improvements, []), get(t, :regressions, [])
        isempty(imps) && isempty(regs) && continue
        metrics = Dict(String(m) => Dict(k => v[k] for k in (:ratios, :gcoff_ratios) if haskey(v, k))
                       for (m, v) in pairs(get(t, :metrics, Dict())) if String(m) in String.(vcat(imps, regs)))
        note = get(t, :note, nothing)
        push!(flagged, Dict("name" => String(name), "improvements" => imps, "regressions" => regs, "metrics" => metrics,
                            "note" => note === nothing ? nothing : first(String(note), 300)))
    end
    sort!(flagged; by=t -> t["name"])
    settings = meta === nothing ? nothing : get(meta, :settings, nothing)
    user = get(pull, :user, nothing)
    return (Int(pull.number), String(something(get(pull, :title, ""), "")), user === nothing ? "" : String(user.login),
            get(pull, :draft, false) === true ? 1 : 0, String(pull.head.sha),
            Int(build.number), String(job.id), String(job.state), Store.iso(Store.parse_upstream(String(build.created_at))),
            at(get(job, :finished_at, nothing)), str_or_missing(get(job, :web_url, nothing)),
            isempty(field(head, :commit)) ? String(build.commit) : field(head, :commit), field(head, :version),
            field(base, :commit), field(base, :version),
            something(get(compare, :blocks, nothing), missing),
            settings === nothing ? missing : something(get(settings, :n_tasks, nothing), missing),
            String(compare.verdict), Int(compare.n_improvements), Int(compare.n_regressions),
            JSON3.write(something(get(compare, :suite, nothing), Dict())), JSON3.write(flagged))
end

# Bring ttfx_prs up to date: a row for every open pull request whose latest finished
# TTFX job produced a comparison, none for closed ones. Closed ones are only dropped
# when the list of open ones is fetched again, so they can linger for PULLS_REFRESH.
function refresh_prs!(db)
    existing = Dict(Int(r.pr_number) => r for r in query(db, "SELECT pr_number, build, job_uuid FROM ttfx_prs"))
    pulls, listed_at, fresh = open_pulls(db)
    fresh && confirm_missing!(pulls, keys(existing))
    since = now(Dates.UTC) - Day(isempty(existing) ? PR_BACKFILL_DAYS : PR_LOOKBACK_DAYS)
    rows = Any[]
    for (n, list) in pr_ttfx_jobs(since)
        known = get(existing, n, nothing)
        isknown(build, job) = known !== nothing && (String(job.id) == known.job_uuid || build.number < known.build)
        isknown(list[1]...) && continue
        pull = get(pulls, n, nothing)
        # Opened since the kept list was taken; asked about now rather than at the next refresh
        if pull === nothing && !fresh && Store.parse_upstream(String(list[1][1].created_at)) > listed_at
            p = github_pull(n)
            pull = p !== nothing && String(p.state) == "open" ? p : nothing
            pull === nothing || (pulls[n] = pull)
        end
        pull === nothing && continue
        for (build, job) in list
            isknown(build, job) && break
            fetched = fetch_job_artifacts(build, job; pipeline=PR_PIPELINE, paths=("ttfx/compare.json", "ttfx/results-meta.json"))
            if fetched === nothing
                @warn "Could not fetch the artifacts; the job is retried next run" pr=n build=build.number
                break
            end
            compare, meta = fetched
            # The job stopped before comparing; an older one may have
            compare === nothing && continue
            push!(rows, pr_row(pull, build, job, compare, meta))
            break
        end
    end
    transaction(db) do
        seq = next_seq!(db)
        stmt = upsert_stmt(db, "ttfx_prs", ["pr_number"], PR_COLS)
        for r in rows
            upsert!(stmt, (r..., seq))
        end
        if fresh
            DBInterface.execute(db, "DELETE FROM ttfx_prs WHERE pr_number NOT IN (SELECT value FROM json_each(?))", (JSON3.write(collect(keys(pulls))),))
            # Only a changed list is written, so that an unchanged one leaves the sequence alone
            DBInterface.execute(db, "INSERT INTO meta VALUES ('ttfx:open_prs', ?1) ON CONFLICT (key) DO UPDATE SET value = ?1 WHERE value IS NOT ?1",
                                (JSON3.write([pull_summary(pulls[n]) for n in sort!(collect(keys(pulls)))]),))
        end
        meta = DBInterface.prepare(db, "UPDATE ttfx_prs SET title = ?1, author = ?2, draft = ?3, pr_head_sha = ?4, head_ref = ?5, base_ref = ?6, change_seq = ?7 " *
                                       "WHERE pr_number = ?8 AND (title IS NOT ?1 OR author IS NOT ?2 OR draft IS NOT ?3 OR pr_head_sha IS NOT ?4 " *
                                       "OR head_ref IS NOT ?5 OR base_ref IS NOT ?6)")
        for r in query(db, "SELECT pr_number FROM ttfx_prs")
            # Between refreshes a row can be for a pull request opened after the kept list was taken
            p = get(pulls, Int(r.pr_number), nothing)
            p === nothing && continue
            user = get(p, :user, nothing)
            DBInterface.execute(meta, (String(something(get(p, :title, ""), "")), user === nothing ? "" : String(user.login),
                                       get(p, :draft, false) === true ? 1 : 0, String(p.head.sha), pr_head_ref(p), String(p.base.ref),
                                       seq, Int(r.pr_number)))
        end
    end
    fresh && DBInterface.execute(db, "INSERT OR REPLACE INTO meta VALUES ('ttfx:open_prs_at', ?)", (Store.iso(listed_at),))
    refresh_ci!(db)
    @info "Open pull requests with a TTFX comparison" updated=length(rows) total=query(db, "SELECT count(*) AS n FROM ttfx_prs")[1].n
    return length(rows)
end

# Build states that no longer change; any other state is looked up again next run
const CI_FINAL_STATES = ("passed", "failed", "canceled", "skipped", "not_run")

# The newest julia-pr build of a commit as (number, state, web_url), nothing when the
# commit has none, missing when the request failed.
function pr_ci_build(sha::String)
    builds = buildkite_get("organizations/$BUILDKITE_ORG/pipelines/$PR_PIPELINE/builds"; params=Dict("commit" => sha, "per_page" => 1))
    builds === nothing && return missing
    isempty(builds) && return nothing
    b = builds[1]
    return (Int(b.number), String(b.state), str_or_missing(get(b, :web_url, nothing)))
end

# Whether CI passes on each pull request's current head: the state of the newest
# julia-pr build of that commit. One request per pull request whose head moved or whose
# build had not finished at the last look, so a quiet hour costs a few requests.
function refresh_ci!(db)
    stale = query(db, "SELECT pr_number, pr_head_sha FROM ttfx_prs WHERE ci_commit IS NOT pr_head_sha " *
                      "OR ci_state IS NULL OR ci_state NOT IN (SELECT value FROM json_each(?))", (JSON3.write(collect(CI_FINAL_STATES)),))
    updates = Any[]
    for r in stale
        sha = String(r.pr_head_sha)
        b = pr_ci_build(sha)
        b === missing && continue
        number, state, url = b === nothing ? (missing, "none", missing) : b
        push!(updates, (number, state, url, sha, Int(r.pr_number)))
    end
    isempty(updates) && return
    transaction(db) do
        seq = next_seq!(db)
        stmt = DBInterface.prepare(db, "UPDATE ttfx_prs SET ci_build = ?1, ci_state = ?2, ci_url = ?3, ci_commit = ?4, change_seq = ?5 " *
                                       "WHERE pr_number = ?6 AND (ci_build IS NOT ?1 OR ci_state IS NOT ?2 OR ci_url IS NOT ?3 OR ci_commit IS NOT ?4)")
        for (number, state, url, sha, pr) in updates
            DBInterface.execute(stmt, (number, state, url, sha, seq, pr))
        end
    end
end

function main(args=ARGS)
    db = open_db(Store.db_path(args); create=false)
    source_run(db, "ttfx") do
        run!(db)
    end
    close(db)
    return 0
end

function run!(db)
    existing = query(db, "SELECT build, job_uuid, n_metrics FROM ttfx_jobs")
    # Rows short of a metric: the recent ones are fetched again, the rest
    # padded (their metric arrays already read as nulls; only the length
    # marker changes)
    builds_desc = sort!(unique(Int(r.build) for r in existing); rev=true)
    refetch_from = isempty(builds_desc) ? 0 : builds_desc[min(REFETCH_BUILDS, end)]
    refetch = Set("$(r.build):$(r.job_uuid)" for r in existing if r.n_metrics < length(METRICS) && r.build >= refetch_from)
    isempty(refetch) || @info "Rows fetched again for the metrics they lack" count=length(refetch)
    known = Set("$(r.build):$(r.job_uuid)" for r in existing if !("$(r.build):$(r.job_uuid)" in refetch))

    new_rows, expired = fetch_new_rows(known; refetch)
    @info "New TTFX rows" count=length(new_rows)
    if isempty(new_rows) && isempty(existing)
        error("No TTFX results found and no existing data - check the token and that julia-ci runs the TTFX job")
    end

    transaction(db) do
        seq = next_seq!(db)
        DBInterface.execute(db, "UPDATE ttfx_jobs SET n_metrics = ?, change_seq = ? WHERE n_metrics < ? AND build < ?",
                            (length(METRICS), seq, length(METRICS), refetch_from))
        # Padded like the old rows: nothing more will ever be fetched for them
        isempty(expired) || DBInterface.execute(db, "UPDATE ttfx_jobs SET n_metrics = ?, change_seq = ? " *
                                                    "WHERE job_uuid IN (SELECT value FROM json_each(?))",
                                                (length(METRICS), seq, JSON3.write(expired)))
        write_rows!(db, new_rows)
    end
    # A trace that cannot be fetched is looked at again next run
    try
        refresh_traces!(db)
    catch e
        @error "Updating the TTFX traces failed" exception=(e, catch_backtrace())
    end
    # GitHub's anonymous quota or a julia-pr listing failing leaves the rows as they
    # were rather than failing the master results with it
    try
        refresh_prs!(db)
    catch e
        @error "Updating the pull request comparisons failed" exception=(e, catch_backtrace())
    end
    return length(new_rows)
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
