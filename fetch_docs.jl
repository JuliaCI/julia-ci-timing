#!/usr/bin/env julia
# Record what the docs jobs of julia-ci master builds print about the manual:
# `doctest` (doctests, then the HTML manual, deployed to docs.julialang.org) and
# `pdf_docs_build` (the PDF manual).
#
# From each log: the public docstrings that are not in the manual (Documenter's
# `checkdocs = :public` warning, since JuliaLang/julia#55267 in November 2026;
# doc/make.jl fails the build when their count differs from the one it records),
# the time of each Documenter stage from the timestamp Buildkite puts on every line,
# the size of the search index and of every HTML page over Documenter's 200 KiB
# warning limit, and the size of the HTML tarball or the PDF the job uploads.
#
# The jobs come from the `jobs` table (fetch_timing.jl), and the logs from
# Buildkite's public log download, which needs no token. Each run fetches the newest
# jobs of the last LOOKBACK_DAYS without a row for TIME_BUDGET and leaves the rest to
# the next. A failed job is recorded too: one that failed on the docstring count
# still prints the list.

using HTTP
using JSON3
using Dates

# The package has the store precompiled
using CITiming.Store
include(joinpath(@__DIR__, "db", "Fetch.jl"))
using SQLite, DBInterface

const CI_PIPELINE = "julia-ci"
const DOCS_JOBS = ["doctest", "pdf_docs_build"]
const LOOKBACK_DAYS = 90
# A log is about 300 KB
const DOWNLOADS = 4
const TIME_BUDGET = Minute(3)

log_url(build, job) = "https://buildkite.com/organizations/$BUILDKITE_ORG/pipelines/$CI_PIPELINE/builds/$build/jobs/$job/download.txt"

# --- the log ------------------------------------------------------------------

const TIMESTAMP = r"\e_bk;t=(\d+)\a"
const ANSI = r"\e\[[0-9;?]*[A-Za-z]"
const MAKE_JL = r"\bjulia\b.*\bdoc/make\.jl\b"
const STAGE_LINE = r"^\[ Info: (SetupBuildDirectory|Doctest|ExpandTemplates|HTMLWriter|LaTeXWriter): (.*)$"
const MISSING_START = r"^┌ Warning: (\d+) docstrings? not included in the manual:"
const MISSING_NAME = r"^│ {4,}(\S.*)$"
const MISSING_END = r"^│ These are docstrings"
const PAGE_LINE = r"^┌ Warning: Generated HTML over size_threshold_warn limit: (\S+)"
const INDEX_LINE = r"^┌ Warning: Generated search index over size_threshold_warn limit"
const FILE_SIZE = r"^│ +Generated file size: ([\d.]+) \((B|KiB|MiB|GiB)\)"
# deploydocs starts by making a fresh clone of the docs repository
const DEPLOY_START = r"^Initialized empty Git repository"
const DEPLOY_END = r"^Build & deploy of docs finished"
const LATEXMK_END = r"^\[ Info: LaTeX sources copied|^Latexmk: All targets .* up-to-date"
# The artifact upload: the file it found, then the bytes it sent
const UPLOAD_FILE = r"Found \d+ files? that match \"([^\"]+)\""
const UPLOAD_BYTES = r"Artifact upload timings: .*\bbytes=([\d.]+) (B|KiB|MiB|GiB)\b"
const OUTPUTS = r"-htmldocs\.tar\.gz$|^TheJuliaLanguage\.pdf$"

const UNITS = Dict("B" => 1 / 1024, "KiB" => 1.0, "MiB" => 1024.0, "GiB" => 1024.0^2)
kib(m) = parse(Float64, m.captures[1]) * UNITS[m.captures[2]]

# The stages in job order: each runs from its first line to the next one's
const STAGES = (:setup_s, :doctest_s, :document_s, :render_s, :deploy_s, :latexmk_s)

"""
    parse_log(text) -> (r, names, pages)

What a docs job's log says, as a Dict of the `docs_jobs` columns (`STAGES`,
`missing_docs`, `search_index_kib`, `output_kib`), each there only when the log has
it; the names of the missing docstrings, sorted; and the KiB of each HTML page over
the warning limit.
"""
function parse_log(text::AbstractString)
    r = Dict{Symbol,Any}()
    names = String[]
    pages = Dict{String,Float64}()
    marks = Dict{Symbol,Float64}()
    t = nothing
    mark!(k) = t === nothing || haskey(marks, k) || (marks[k] = t)
    in_missing = false
    sized = nothing      # the page or index whose size the next lines give
    upload = nothing
    for raw in eachsplit(text, '\n')
        m = match(TIMESTAMP, raw)
        m === nothing || (t = parse(Int, m.captures[1]) / 1000)
        line = rstrip(replace(raw, TIMESTAMP => "", ANSI => "", '\r' => ""))
        isempty(line) && continue
        if in_missing
            if occursin(MISSING_END, line) || !startswith(line, "│")
                in_missing = false
            elseif (m = match(MISSING_NAME, line)) !== nothing
                push!(names, String(m.captures[1]))
            end
            continue
        end
        if (m = match(STAGE_LINE, line)) !== nothing
            stage, what = m.captures
            if stage == "SetupBuildDirectory"
                mark!(:setup_end)
            elseif stage == "Doctest"
                startswith(what, "skipped") || mark!(:doctest)
            elseif stage == "ExpandTemplates"
                mark!(:document)
            elseif stage == "HTMLWriter" || startswith(what, "creating")
                mark!(:render)
            elseif occursin("latexmk", what)
                mark!(:latexmk)
            end
        elseif occursin(MAKE_JL, line)
            mark!(:setup)
        elseif (m = match(MISSING_START, line)) !== nothing
            r[:missing_docs] = parse(Int, m.captures[1])
            empty!(names)
            in_missing = true
        elseif (m = match(PAGE_LINE, line)) !== nothing
            sized = String(m.captures[1])
        elseif occursin(INDEX_LINE, line)
            sized = :index
        elseif sized !== nothing && (m = match(FILE_SIZE, line)) !== nothing
            sized === :index ? (r[:search_index_kib] = kib(m)) : (pages[sized] = kib(m))
            sized = nothing
        elseif occursin(DEPLOY_START, line)
            mark!(:deploy)
        elseif occursin(DEPLOY_END, line)
            mark!(:deploy_end)
        elseif occursin(LATEXMK_END, line)
            mark!(:latexmk_end)
        elseif (m = match(UPLOAD_FILE, line)) !== nothing
            upload = String(m.captures[1])
        elseif upload !== nothing && (m = match(UPLOAD_BYTES, line)) !== nothing
            occursin(OUTPUTS, upload) && (r[:output_kib] = kib(m))
            upload = nothing
        end
    end
    span!(col, from, to...) = for e in to
        if haskey(marks, from) && haskey(marks, e)
            r[col] = round(marks[e] - marks[from]; digits=1)
            break
        end
    end
    span!(:setup_s, :setup, :setup_end)
    # The PDF job skips the doctests, so its document stage starts at the setup's end
    span!(:doctest_s, :doctest, :document)
    haskey(marks, :doctest) ? span!(:document_s, :document, :render) : span!(:document_s, :setup_end, :render)
    span!(:render_s, :render, :deploy, :latexmk)
    span!(:deploy_s, :deploy, :deploy_end)
    span!(:latexmk_s, :latexmk, :latexmk_end)
    haskey(r, :missing_docs) && length(names) != r[:missing_docs] && @warn "The missing docstrings listed differ from their count" count=r[:missing_docs] listed=length(names)
    return r, sort!(unique!(names)), pages
end

# --- the jobs -------------------------------------------------------------------

# The docs jobs of the last `days` without a row, newest first. A retried job is
# left out: its retry is the one that counts.
function pending_jobs(db; days=LOOKBACK_DAYS)
    since = Store.iso(now(UTC) - Day(days))
    return [(job=String(r.job_uuid), build=Int(r.build), commit=String(r.commit_sha), name=String(r.name),
             agent=String(r.agent), state=String(r.state), started_at=r.started_at, finished_at=r.finished_at)
            for r in query(db, """
                SELECT j.job_uuid, b.number AS build, b.commit_sha, j.name, j.agent_hostname AS agent, j.state,
                       j.started_at, j.finished_at
                FROM jobs j JOIN builds b ON b.id = j.build_id
                WHERE b.pipeline = ? AND b.branch = 'master' AND j.state IN ('passed', 'failed')
                  AND coalesce(j.retried, 0) = 0 AND j.job_uuid IS NOT NULL AND b.commit_sha IS NOT NULL
                  AND j.started_at >= ? AND j.name IN (SELECT value FROM json_each(?))
                  AND NOT EXISTS (SELECT 1 FROM docs_jobs d WHERE d.job_uuid = j.job_uuid)
                ORDER BY b.number DESC, j.name""", (CI_PIPELINE, since, JSON3.write(DOCS_JOBS)))]
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

const JOB_COLS = ["build", "commit_sha", "job_name", "agent", "job_state", "started_at", "finished_at", "state",
                  String.(STAGES)..., "missing_docs", "missing_set", "search_index_kib", "output_kib"]

# A log with none of it (expired, or a job that failed before the manual) is
# 'unparsed', so it is not fetched again
parsed(r) = any(s -> haskey(r, s), STAGES) || haskey(r, :missing_docs)

# The id of a list of missing docstrings, kept once however many jobs printed it
function missing_set!(db, names)
    text = join(names, '\n')
    DBInterface.execute(db, "INSERT OR IGNORE INTO docs_missing_sets (names, count) VALUES (?, ?)", (text, length(names)))
    return Int(query(db, "SELECT id FROM docs_missing_sets WHERE names = ?", (text,))[1].id)
end

function write_jobs!(db, results)
    transaction(db) do
        seq = next_seq!(db)
        jobs = upsert_stmt(db, "docs_jobs", ["job_uuid"], JOB_COLS)
        pagestmt = upsert_stmt(db, "docs_pages", ["job_uuid", "page"], ["kib"]; seq=false)
        for (job, (r, names, pages)) in results
            ok = parsed(r)
            set = ok && haskey(r, :missing_docs) ? missing_set!(db, names) : missing
            v(k) = get(r, k, missing)
            upsert!(jobs, (job.job, job.build, job.commit, job.name, job.agent, job.state, job.started_at, job.finished_at,
                           ok ? "ok" : "unparsed", (v(s) for s in STAGES)..., v(:missing_docs), set,
                           v(:search_index_kib), v(:output_kib), seq))
            for (page, k) in pages
                upsert!(pagestmt, (job.job, page, round(k; digits=2)))
            end
        end
    end
end

# Fetch and record `jobs` in order, DOWNLOADS at a time, until `deadline`
function fetch_jobs!(db, jobs; deadline=nothing)
    written = 0
    unparsed = 0
    empty = (Dict{Symbol,Any}(), String[], Dict{String,Float64}())
    for batch in Iterators.partition(jobs, DOWNLOADS)
        if deadline !== nothing && now(UTC) > deadline
            @info "Out of time; the rest is left to the next run" left=length(jobs) - written
            break
        end
        logs = asyncmap(fetch_log, batch)
        results = [(job, text === nothing ? empty : parse_log(text)) for (job, text) in zip(batch, logs) if text !== missing]
        isempty(results) && continue
        # Each batch in its own transaction, so a run that is stopped keeps what it fetched
        write_jobs!(db, results)
        written += length(results)
        unparsed += count(((_, (r, _, _)),) -> !parsed(r), results)
    end
    @info "Recorded the docs jobs" jobs=written unparsed
    return written
end

function main(args=ARGS)
    db = open_db(Store.db_path(args); create=false)
    source_run(db, "docs") do
        jobs = pending_jobs(db)
        @info "Docs jobs to fetch" count=length(jobs)
        fetch_jobs!(db, jobs; deadline=now(UTC) + TIME_BUDGET)
    end
    close(db)
    return 0
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
