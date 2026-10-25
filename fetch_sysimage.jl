#!/usr/bin/env julia
# Record how long the build jobs of julia-ci master builds spend making the system
# image, stage by stage, from their logs.
#
# The build prints the time of most stages: compiling the compiler
# ("Base.Compiler ──"), the Sysimage built summary (Base, the stdlibs it loads, each
# of those), running the precompile statements and emitting sys ("Output ──"). The
# two stages it prints nothing for, emitting basecompiler and sysbase, are the time
# from the summary line before them to the link of the image, from the timestamp
# Buildkite puts on every line. The stdlib pkgimages precompiled after the image are
# recorded too.
#
# The jobs come from the `jobs` table (fetch_timing.jl), and the logs from
# Buildkite's public log download, which needs no token. Each run fetches the newest
# jobs of the last LOOKBACK_DAYS without a row for TIME_BUDGET and leaves the rest to
# the next. The jobs table has no UUIDs for the builds before julia-ci build 569
# (September 2026), imported from the old files: the first run with a token lists
# those builds from the Buildkite API once (meta sysimage:listed_old) and records
# their build jobs as state 'pending', fetched like the rest.

using HTTP
using JSON3
using Dates

# The package has the store precompiled
using CITiming.Store
include(joinpath(@__DIR__, "db", "Fetch.jl"))
using SQLite, DBInterface

const CI_PIPELINE = "julia-ci"
const BUILD_JOBS = [":linux: build x86_64-linux-gnu", ":linux: build aarch64-linux-gnu",
                    ":macos: build aarch64-apple-darwin", ":windows: build x86_64-w64-mingw32"]
const LOOKBACK_DAYS = 90
# A log is 1 to 2 MB and takes about a second; this many at once
const DOWNLOADS = 4
const TIME_BUDGET = Minute(5)

log_url(build, job) = "https://buildkite.com/organizations/$BUILDKITE_ORG/pipelines/$CI_PIPELINE/builds/$build/jobs/$job/download.txt"

# --- the log ------------------------------------------------------------------

# Buildkite's timestamp at the start of a line, in milliseconds
const TIMESTAMP = r"\e_bk;t=(\d+)\a"
const ANSI = r"\e\[[0-9;?]*[A-Za-z]"
# The three julia commands that make the images, by their script: basecompiler,
# sysbase and sys
const IMAGE_COMMAND = r"\b(?:Base_compiler|sysimg|generate_precompile)\.jl\b"
const SECONDS = raw"([\d.]+) seconds"
const COMPILER_LINE = Regex("^Base\\.Compiler ─+ " * SECONDS)
# "Base  ────── 131.5 seconds" opens the per-module lines before the summary, whose
# own "Base ──── 131.5 seconds 77.6%" has one space and a share
const MODULES_START = Regex("^Base +─+ *" * SECONDS * "\$")
const MODULES_END = Regex("^Stdlibs total +─+ *" * SECONDS)
const MODULE_LINE = Regex("^(\\w+) +─+ *" * SECONDS * "\$")
const SUMMARY_BASE = Regex("^Base ─+ *" * SECONDS * " [\\d.]+%")
const SUMMARY_STDLIBS = Regex("^Stdlibs ─+ *" * SECONDS * " [\\d.]+%")
const TOTAL_LINE = Regex("^Total ─+ *" * SECONDS)
const STATEMENTS_LINE = r"^Executed (\d+) precompile statements"
const OUTPUT_LINE = Regex("^Output ─+ *" * SECONDS)
const LINK_BASECOMPILER = r"-o \S*basecompiler\.(?:so|dylib|dll)\b"
const LINK_SYSBASE = r"-o \S*sysbase\.(?:so|dylib|dll)\b"
# Linked by Base.Linking since October 2026, by the compiler driver before
const LINK_SYS = r"link_image\(.*is_sysimage=true|-o \S*/sys\.(?:so|dylib|dll)(?: |$)"
const PKGIMAGES_LINE = r"(\d+) dependencies successfully precompiled in (\d+) seconds"

const STAGES = (:compiler_s, :compiler_output_s, :base_s, :stdlibs_s, :sysbase_output_s, :precompile_s, :sys_output_s)

"""
    parse_log(text) -> (stages, stdlibs)

The stage times of one build job's log as a Dict of the `sysimage_jobs` columns
(`STAGES`, `precompile_statements`, `stdlib_pkgimages_s`, `stdlib_pkgimages`), each
there only when the log has it, and the seconds of each stdlib loaded into the image.
"""
function parse_log(text::AbstractString)
    r = Dict{Symbol,Any}()
    stdlibs = Dict{String,Float64}()
    t = nothing          # the latest line timestamp, in seconds
    commands = 0
    in_modules = false
    totals = 0
    marks = Dict{Symbol,Float64}()
    secs(m, i=1) = parse(Float64, m.captures[i])
    for raw in eachsplit(text, '\n')
        m = match(TIMESTAMP, raw)
        m === nothing || (t = parse(Int, m.captures[1]) / 1000)
        line = strip(replace(raw, TIMESTAMP => "", ANSI => "", '\r' => ""))
        isempty(line) && continue
        if occursin(IMAGE_COMMAND, line) && occursin("base &&", line)
            commands += 1
        elseif (m = match(COMPILER_LINE, line)) !== nothing
            r[:compiler_s] = secs(m)
            t === nothing || (marks[:compiler] = t)
        elseif occursin(LINK_BASECOMPILER, line)
            t === nothing || (marks[:basecompiler] = t)
        elseif occursin(LINK_SYSBASE, line)
            t === nothing || (marks[:sysbase] = t)
        elseif match(MODULES_START, line) !== nothing
            in_modules = true
        elseif in_modules && match(MODULES_END, line) !== nothing
            in_modules = false
        elseif in_modules && (m = match(MODULE_LINE, line)) !== nothing
            stdlibs[m.captures[1]] = secs(m, 2)
        elseif (m = match(SUMMARY_BASE, line)) !== nothing
            r[:base_s] = secs(m)
        elseif (m = match(SUMMARY_STDLIBS, line)) !== nothing
            r[:stdlibs_s] = secs(m)
        elseif (m = match(TOTAL_LINE, line)) !== nothing
            # The Sysimage built summary's, then Precompilation complete's
            totals += 1
            if totals == 1
                t === nothing || (marks[:summary] = t)
            elseif totals == 2
                r[:precompile_s] = secs(m)
            end
        elseif (m = match(STATEMENTS_LINE, line)) !== nothing
            r[:precompile_statements] = parse(Int, m.captures[1])
        elseif (m = match(OUTPUT_LINE, line)) !== nothing
            r[:sys_output_s] = secs(m)
        elseif occursin(LINK_SYS, line)
            marks[:sys] = something(t, NaN)
        elseif haskey(marks, :sys) && !haskey(r, :stdlib_pkgimages) && (m = match(PKGIMAGES_LINE, line)) !== nothing
            r[:stdlib_pkgimages] = parse(Int, m.captures[1])
            r[:stdlib_pkgimages_s] = secs(m, 2)
        end
    end
    haskey(marks, :compiler) && haskey(marks, :basecompiler) && (r[:compiler_output_s] = marks[:basecompiler] - marks[:compiler])
    haskey(marks, :summary) && haskey(marks, :sysbase) && (r[:sysbase_output_s] = marks[:sysbase] - marks[:summary])
    # A log that ran the image commands more than once (a retried make) cannot be
    # told apart stage by stage
    commands > 3 && empty!(r)
    return r, stdlibs
end

# --- the jobs -------------------------------------------------------------------

# The build jobs of the last `days` to fetch, newest first: those of the jobs table
# without a row, and the pending rows of the builds listed from the API
function pending_jobs(db; days=LOOKBACK_DAYS)
    since = Store.iso(now(UTC) - Day(days))
    return [(job=String(r.job_uuid), build=Int(r.build), commit=String(r.commit_sha), name=String(r.name),
             agent=String(r.agent), started_at=r.started_at, finished_at=r.finished_at)
            for r in query(db, """
                SELECT j.job_uuid, b.number AS build, b.commit_sha, j.name, j.agent_hostname AS agent, j.started_at, j.finished_at
                FROM jobs j JOIN builds b ON b.id = j.build_id
                WHERE b.pipeline = ? AND b.branch = 'master' AND j.state = 'passed' AND j.job_uuid IS NOT NULL
                  AND b.commit_sha IS NOT NULL AND j.started_at >= ? AND j.name IN (SELECT value FROM json_each(?))
                  AND NOT EXISTS (SELECT 1 FROM sysimage_jobs s WHERE s.job_uuid = j.job_uuid)
                UNION ALL
                SELECT job_uuid, build, commit_sha, job_name, coalesce(agent, ''), started_at, finished_at
                FROM sysimage_jobs WHERE state = 'pending' AND started_at >= ?
                ORDER BY build DESC, name""", (CI_PIPELINE, since, JSON3.write(BUILD_JOBS), since))]
end

const LISTED_OLD_KEY = "sysimage:listed_old"

at(x) = x === nothing ? missing : Store.iso(Store.parse_upstream(String(x)))

# Once: the build jobs of the master builds of the last `days` that are older than
# the first one the jobs table has UUIDs for, from the Buildkite API, recorded as
# pending rows. A listing page holds every job of 100 builds (about 30 MB), so it is
# not repeated.
function list_old_jobs!(db; days=LOOKBACK_DAYS)
    isempty(query(db, "SELECT 1 FROM meta WHERE key = ?", (LISTED_OLD_KEY,))) || return 0
    from = Store.iso(now(UTC) - Day(days))
    first_known = query(db, """
        SELECT min(b.created_at) AS t FROM builds b JOIN jobs j ON j.build_id = b.id
        WHERE b.pipeline = ? AND b.branch = 'master' AND j.job_uuid IS NOT NULL""", (CI_PIPELINE,))[1].t
    rows = NamedTuple[]
    if first_known !== missing && first_known > from
        buildkite_pages("organizations/$BUILDKITE_ORG/pipelines/$CI_PIPELINE/builds",
                        ["branch" => "master", "created_from" => from, "created_to" => first_known]; max_pages=20) do builds, page
            for build in builds, job in get(build, :jobs, [])
                get(job, :type, nothing) == "script" || continue
                String(something(get(job, :name, nothing), "")) in BUILD_JOBS || continue
                get(job, :state, nothing) == "passed" || continue
                get(job, :retried, false) === true && continue
                agent = get(job, :agent, nothing)
                push!(rows, (job=String(job.id), build=Int(build.number), commit=String(build.commit), name=String(job.name),
                             agent=agent === nothing ? "" : String(something(get(agent, :hostname, nothing), "")),
                             started_at=at(get(job, :started_at, nothing)), finished_at=at(get(job, :finished_at, nothing))))
            end
            @info "Listed the builds before the jobs table's UUIDs, page $page" jobs=length(rows)
        end
    end
    transaction(db) do
        seq = next_seq!(db)
        # Inserted only where there is no row, so a fetched job is never made pending again
        stmt = DBInterface.prepare(db, "INSERT OR IGNORE INTO sysimage_jobs (job_uuid, build, commit_sha, job_name, triplet, agent, " *
                                       "started_at, finished_at, state, change_seq) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)")
        for r in rows
            DBInterface.execute(stmt, (r.job, r.build, r.commit, r.name, triplet(r.name), r.agent, r.started_at, r.finished_at, seq))
        end
        DBInterface.execute(db, "INSERT OR REPLACE INTO meta VALUES (?, ?)", (LISTED_OLD_KEY, Store.iso_now()))
    end
    return length(rows)
end

# The log of a job, nothing when it is gone (Buildkite drops old ones) and missing
# when the download failed, to be tried again next run
function fetch_log(job)
    resp = try
        http_get_retry(log_url(job.build, job.job), ["User-Agent" => "julia-ci-timing-fetcher"])
    catch e
        @warn "Downloading the log failed" build=job.build job=job.name exception=e
        return missing
    end
    resp.status == 200 && return String(resp.body)
    resp.status in (404, 410) && return nothing
    @warn "Downloading the log failed" build=job.build job=job.name status=resp.status
    return missing
end

const JOB_COLS = ["build", "commit_sha", "job_name", "triplet", "agent", "started_at", "finished_at", "state",
                  String.(STAGES)..., "precompile_statements", "stdlib_pkgimages_s", "stdlib_pkgimages"]

triplet(name) = (m = match(r"build (\S+)$", name); m === nothing ? name : String(m.captures[1]))

function write_jobs!(db, results)
    transaction(db) do
        seq = next_seq!(db)
        jobs = upsert_stmt(db, "sysimage_jobs", ["job_uuid"], JOB_COLS)
        libs = upsert_stmt(db, "sysimage_stdlibs", ["job_uuid", "stdlib"], ["seconds"]; seq=false)
        for (job, (stages, stdlibs)) in results
            ok = all(s -> haskey(stages, s), STAGES)
            ok || (stages = Dict{Symbol,Any}(); stdlibs = Dict{String,Float64}())
            v(k) = get(stages, k, missing)
            upsert!(jobs, (job.job, job.build, job.commit, job.name, triplet(job.name), job.agent, job.started_at, job.finished_at,
                           ok ? "ok" : "unparsed", (v(s) for s in STAGES)..., v(:precompile_statements),
                           v(:stdlib_pkgimages_s), v(:stdlib_pkgimages), seq))
            for (name, s) in stdlibs
                upsert!(libs, (job.job, name, s))
            end
        end
    end
end

# Fetch and record `jobs` in order, DOWNLOADS at a time, until `deadline`
function fetch_jobs!(db, jobs; deadline=nothing)
    written = 0
    unparsed = 0
    for batch in Iterators.partition(jobs, DOWNLOADS)
        if deadline !== nothing && now(UTC) > deadline
            @info "Out of time; the rest is left to the next run" left=length(jobs) - written
            break
        end
        logs = asyncmap(fetch_log, batch)
        results = [(job, text === nothing ? (Dict{Symbol,Any}(), Dict{String,Float64}()) : parse_log(text))
                   for (job, text) in zip(batch, logs) if text !== missing]
        isempty(results) && continue
        # Each batch in its own transaction, so a run that is stopped keeps what it fetched
        write_jobs!(db, results)
        written += length(results)
        unparsed += count(((_, (stages, _)),) -> !all(s -> haskey(stages, s), STAGES), results)
    end
    @info "Recorded the sysimage stages" jobs=written unparsed
    return written
end

function main(args=ARGS)
    db = open_db(Store.db_path(args); create=false)
    source_run(db, "sysimage") do
        # Without a token (a local run) the old builds wait for a run that has one
        try
            n = list_old_jobs!(db)
            n > 0 && @info "Recorded the build jobs of the older builds as pending" count=n
        catch e
            @warn "Listing the older builds failed; tried again next run" exception=e
        end
        jobs = pending_jobs(db)
        @info "Build jobs to fetch" count=length(jobs)
        fetch_jobs!(db, jobs; deadline=now(UTC) + TIME_BUDGET)
    end
    close(db)
    return 0
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
