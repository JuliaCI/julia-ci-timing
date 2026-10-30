#!/usr/bin/env julia
# Fetch the runtime benchmark results from the julia-ci and julia-pr pipelines on Buildkite.
#
# The `Runtime benchmarks` job runs JuliaCI/julia-ci-benchmarks on the macOS aarch64 agent:
# about 200 benchmarks in 14 categories, each (block, category, arm) in its own process.
# On julia-ci it measures the build alone (one arm, `head`); on julia-pr it measures the
# pull request's head against the master build of its merge-base, interleaved, and judges
# the difference into compare.json. The job uploads, under runtime-benchmarks/out/,
# results.json (one record per benchmark, arm and block), results-meta.json (the builds,
# the machine and the settings), report.md and, on julia-pr, compare.json.
#
# For every finished job of a julia-ci master or release branch build this keeps one row
# in rtb_jobs and one per benchmark in rtb_results, reduced over the blocks: the minimum
# of the judged metric (cycles, or wall time for the benchmarks whose work leaves the
# calling thread), its maximum over blocks, the retired instructions, the wall time,
# allocations and the per-block values. The parsed artifacts are kept, compressed, in
# raw_rtb. rtb_prs keeps the latest compare.json of each open pull request (see below).
# The weekly julia-ci build that measures published releases (TTFX_RELEASE) runs the
# job on the newest stable release (kind 'release'), the LTS ('lts') and the nightly of
# the next release's branch ('branch_nightly'); their rows sit beside the master ones.
# The backfill of master commits measured before CI ran the job, from manyjulias builds
# on another machine, comes as a bundle published with julia-ci-benchmarks (see below);
# its rows have pipeline 'manyjulias'.
#
# A run is idempotent: a job with a row is not fetched again.
#
#   julia --project fetch_runtime.jl [--db PATH]

using HTTP
using JSON3
using Dates
using CodecZlib

# The package has the store precompiled
using CITiming.Store
include(joinpath(@__DIR__, "db", "Fetch.jl"))
using SQLite, DBInterface

const CI_PIPELINE = "julia-ci"
const PR_PIPELINE = "julia-pr"
# ":macos: Runtime benchmarks aarch64-apple-darwin", or ":macos: Runtime benchmarks
# release <triplet>" (also lts, branch nightly) for the weekly references; the triplet
# keeps a group step of the same name from matching
const RTB_JOB = r"\bRuntime benchmarks\s+(?:(release|lts|branch nightly)\s+)?([a-z0-9_]+-[a-z0-9_-]+)$"
const FINISHED_STATES = ("passed", "failed", "timed_out")
const ARTIFACT_DIR = "runtime-benchmarks/out/"
# The parsed results are some MB of samples per job; the store keeps them at a higher
# compression level than the other raw tables
const RAW_ZSTD_LEVEL = 19

# --- one job's results ---------------------------------------------------------

counters_of(r) = something(get(r, :counters, nothing), Dict())
has_counter(r, key) = (c = get(counters_of(r), key, nothing); c !== nothing && !isempty(c))

# What compare.jl in julia-ci-benchmarks judges a record on: the counter the benchmark asks
# for (cycles, or instructions) when the backend recorded it, else wall time
function record_metric(r)
    m = String(get(r, :metric, "time"))
    return m in ("cycles", "instructions") && has_counter(r, Symbol(m)) ? m : "time"
end
record_value(r, metric) = metric == "time" ? Float64(r.min_ns) : Float64(minimum(counters_of(r)[Symbol(metric)]))
record_instructions(r) = has_counter(r, :instructions) ? Float64(minimum(counters_of(r)[:instructions])) : nothing

num(x) = x === nothing ? nothing : Float64(x)
int(x) = x === nothing ? nothing : round(Int, x)
minornothing(v) = (v = filter(!isnothing, v); isempty(v) ? nothing : minimum(v))
maxornothing(v) = (v = filter(!isnothing, v); isempty(v) ? nothing : maximum(v))

"""
    summarize_records(records, arm) -> Dict{String,Dict}

The records of one arm reduced over their blocks, per benchmark: the minimum and maximum
over blocks of the judged metric's per-block minimum, the minimum instructions, wall
time, allocations and bytes, and each block's values. A benchmark none of whose blocks
ran is kept with its status and first error.
"""
function summarize_records(records, arm)
    byname = Dict{String,Vector{Any}}()
    for r in records
        String(get(r, :arm, "")) == arm || continue
        push!(get!(byname, String(r.name), Any[]), r)
    end
    out = Dict{String,Dict{String,Any}}()
    for (name, recs) in byname
        sort!(recs; by=r -> something(get(r, :block, nothing), 0))
        ok = filter(r -> get(r, :status, "") == "ok", recs)
        bad = findfirst(r -> get(r, :status, "") != "ok", recs)
        err = bad === nothing ? nothing : first(String(something(get(recs[bad], :error, nothing), String(recs[bad].status))), 500)
        status = !isempty(ok) ? "ok" : all(r -> get(r, :status, "") == "skipped", recs) ? "skipped" : "error"
        r1 = isempty(ok) ? recs[1] : ok[1]
        metric = record_metric(r1)
        values = [record_value(r, metric) for r in ok]
        ns = [Float64(r.min_ns) for r in ok]
        instr = [record_instructions(r) for r in ok]
        tol = get(r1, :tolerance, nothing)
        out[name] = Dict{String,Any}(
            "category" => String(get(r1, :category, first(split(name, '/')))), "metric" => metric, "status" => status,
            "error" => err, "blocks" => length(ok),
            "value" => isempty(values) ? nothing : minimum(values), "value_max" => isempty(values) ? nothing : maximum(values),
            "instructions" => minornothing(instr), "min_ns" => isempty(ns) ? nothing : minimum(ns),
            "median_ns" => minornothing([num(get(r, :median_ns, nothing)) for r in ok]),
            "allocs" => int(minornothing([num(get(r, :allocs, nothing)) for r in ok])),
            "bytes" => int(minornothing([num(get(r, :bytes, nothing)) for r in ok])),
            "ops" => int(num(get(r1, :ops, nothing))), "tolerance" => num(tol),
            "block_values" => values, "block_ns" => ns, "block_instructions" => instr)
    end
    return out
end

# The arm a single-build job measured: `head`, or the last one it ran
function measured_arm(meta)
    order = meta === nothing ? [] : String.(get(meta, :arm_order, []))
    return "head" in order || isempty(order) ? "head" : order[end]
end

str(x) = x === nothing ? "" : String(x)
getin(x, keys...) = (for k in keys; x === nothing && return nothing; x = get(x, k, nothing); end; x)

function build_message(build)
    message = first(split(String(something(get(build, :message, ""), "")), '\n'))
    return length(message) > 80 ? first(message, 77) * "..." : message
end

"""
    job_row(build, job, results, meta) -> Dict

One julia-ci job's row and its benchmarks, from the Buildkite build and job and the
parsed artifacts (either nothing when the job did not upload it).
"""
function job_row(build, job, results, meta)
    arm = measured_arm(meta)
    head = getin(meta, :arms, Symbol(arm))
    benchmarks = results === nothing ? Dict{String,Dict{String,Any}}() : summarize_records(results, arm)
    branch = String(something(get(build, :branch, "master"), "master"))
    backend = results === nothing || isempty(results) ? "" : str(get(results[1], :counters_backend, nothing))
    failures = getin(meta, :failures)
    m = match(RTB_JOB, String(something(get(job, :name, ""), "")))
    kind = m !== nothing && m.captures[1] !== nothing ? replace(String(m.captures[1]), ' ' => '_') :
           branch == "master" ? "master" : "release_branch"
    return Dict{String,Any}(
        "job_uuid" => String(job.id), "build" => Int(build.number), "kind" => kind,
        "state" => String(get(job, :state, "unknown")),
        "build_created_at" => Store.iso(Store.parse_upstream(String(build.created_at))),
        "commit_sha" => isempty(str(getin(head, :commit))) ? String(build.commit) : str(getin(head, :commit)),
        "message" => build_message(build), "version" => str(getin(head, :version)), "llvm" => str(getin(head, :llvm)),
        "cpu_target" => str(getin(head, :cpu_target)), "agent" => str(getin(job, :agent, :hostname)),
        "machine" => str(getin(meta, :machine, :cpu)), "suite_commit" => str(getin(meta, :suite_commit)),
        "counters_backend" => backend, "blocks" => getin(meta, :settings, :blocks), "threads" => getin(meta, :settings, :threads),
        "n_benchmarks" => length(benchmarks), "n_failed" => count(b -> b["status"] != "ok", values(benchmarks)),
        "failures" => failures === nothing ? nothing : JSON3.write(failures), "duration_s" => num(getin(meta, :duration_s)),
        "started_at" => at(get(job, :started_at, nothing)), "finished_at" => at(get(job, :finished_at, nothing)),
        "web_url" => (u = get(job, :web_url, nothing); u === nothing ? nothing : String(u)), "has_results" => results === nothing ? 0 : 1,
        "benchmarks" => benchmarks, "_results" => results, "_meta" => meta)
end

at(x) = x === nothing ? missing : Store.iso(Store.parse_upstream(String(x)))
miss(x) = x === nothing ? missing : x
jsonarr(v) = JSON3.write(v)

const JOB_COLS = ["pipeline", "build", "kind", "state", "build_created_at", "commit_sha", "message", "version", "llvm", "cpu_target",
                  "agent", "machine", "suite_commit", "counters_backend", "blocks", "threads", "n_benchmarks", "n_failed", "failures",
                  "duration_s", "started_at", "finished_at", "web_url", "has_results"]
const RESULT_COLS = ["job_uuid", "name", "category", "metric", "status", "error", "blocks", "value", "value_max", "instructions",
                     "min_ns", "median_ns", "allocs", "bytes", "ops", "tolerance", "block_values", "block_ns", "block_instructions"]

"""
    write_rows!(db, rows; pipeline=CI_PIPELINE, raw=true)

Store `job_row`s, each replacing whatever its job had before, in the caller's transaction.
`raw` keeps the parsed artifacts in raw_rtb as well.
"""
function write_rows!(db, rows; pipeline=CI_PIPELINE, raw=true)
    isempty(rows) && return 0
    seq = next_seq!(db)
    job = upsert_stmt(db, "rtb_jobs", ["job_uuid"], JOB_COLS)
    result = DBInterface.prepare(db, "INSERT INTO rtb_results ($(join(RESULT_COLS, ", "))) VALUES ($(join(fill("?", length(RESULT_COLS)), ", ")))")
    raw_stmt = DBInterface.prepare(db, "INSERT OR REPLACE INTO raw_rtb (job_uuid, fetched_at, results_zst, meta_zst) VALUES (?, ?, ?, ?)")
    for r in rows
        uuid = r["job_uuid"]
        upsert!(job, (uuid, pipeline, (miss(r[c]) for c in JOB_COLS[2:end])..., seq))
        DBInterface.execute(db, "DELETE FROM rtb_results WHERE job_uuid = ?", (uuid,))
        for name in sort!(collect(keys(r["benchmarks"])))
            b = r["benchmarks"][name]
            DBInterface.execute(result, (uuid, name, b["category"], b["metric"], b["status"], miss(b["error"]), b["blocks"],
                                         miss(b["value"]), miss(b["value_max"]), miss(b["instructions"]), miss(b["min_ns"]),
                                         miss(b["median_ns"]), miss(b["allocs"]), miss(b["bytes"]), miss(b["ops"]), miss(b["tolerance"]),
                                         jsonarr(b["block_values"]), jsonarr(b["block_ns"]), jsonarr(b["block_instructions"])))
        end
        raw || continue
        # The artifacts expire on Buildkite; keep what was parsed
        pack(x) = x === nothing ? missing : compress_zst(JSON3.write(x); level=RAW_ZSTD_LEVEL)
        DBInterface.execute(raw_stmt, (uuid, iso_now(), pack(r["_results"]), pack(r["_meta"])))
    end
    return length(rows)
end

# --- julia-ci ------------------------------------------------------------------

# The parsed artifacts named `paths` (under ARTIFACT_DIR) of a job, each nothing when the
# job did not upload it; nothing altogether when the listing or a download failed, so
# the caller leaves the job for the next run instead of recording an empty row.
function fetch_job_artifacts(pipeline, build, job, paths)
    artifacts = buildkite_get("organizations/$BUILDKITE_ORG/pipelines/$pipeline/builds/$(build.number)/jobs/$(job.id)/artifacts")
    artifacts === nothing && return nothing
    out = Any[]
    for path in paths
        i = findfirst(a -> String(get(a, :path, "")) == ARTIFACT_DIR * path && String(get(a, :state, "")) == "finished", artifacts)
        if i === nothing
            push!(out, nothing)
            continue
        end
        body = download_artifact(String(artifacts[i].download_url))
        body === nothing && return nothing
        push!(out, JSON3.read(body))
    end
    return Tuple(out)
end

# New rows for finished jobs not in `known` (job UUIDs). Builds are listed newest first;
# a run stops once a page reaches the builds counted as captured (older than the 50
# newest with a row) or, before any row exists, once a page has no such job at all: the
# job only exists from a point on. A failed listing throws, so the run is recorded as
# failed rather than as one that found nothing.
function fetch_new_rows(known::Set{String}, known_builds::Vector{Int}; max_pages=30)
    rows = Dict{String,Any}[]
    sort!(known_builds; rev=true)
    min_known = isempty(known_builds) ? 0 : known_builds[min(50, end)]
    seen_any = false
    buildkite_pages("organizations/$BUILDKITE_ORG/pipelines/$CI_PIPELINE/builds"; max_pages) do builds, page
        found = 0
        oldest = typemax(Int)
        for build in builds
            oldest = min(oldest, build.number)
            branch = String(something(get(build, :branch, "master"), "master"))
            (branch == "master" || startswith(branch, "release-")) || continue
            for job in get(build, :jobs, [])
                get(job, :type, nothing) == "script" || continue
                name = get(job, :name, nothing)
                (name === nothing || match(RTB_JOB, String(name)) === nothing) && continue
                found += 1
                uuid = String(job.id)
                uuid in known && continue
                String(get(job, :state, "")) in FINISHED_STATES || continue
                @info "Fetching runtime benchmark results" build=build.number state=String(job.state)
                fetched = fetch_job_artifacts(CI_PIPELINE, build, job, ("results.json", "results-meta.json"))
                if fetched === nothing
                    @warn "Could not fetch the artifacts; the job is retried next run" build=build.number
                    continue
                end
                results, meta = fetched
                results === nothing && @info "No results artifact" build=build.number
                push!(rows, job_row(build, job, results, meta))
                push!(known, uuid)
            end
        end
        @info "Fetched page $page" jobs=found new=length(rows) oldest
        seen_any |= found > 0
        oldest < min_known && return :stop
        isempty(known_builds) && seen_any && found == 0 && return :stop
    end
    return rows
end

# --- pull requests ---------------------------------------------------------------
#
# On julia-pr the job measures the head against the master build of the merge-base and
# uploads compare.json. rtb_prs keeps the latest one of each open pull request; a
# closed one's row is deleted.

const PR_BACKFILL_DAYS = 30
# The job runs on the same macOS machine as TTFX and can finish a day or more after its
# build was created, behind that queue
const PR_LOOKBACK_DAYS = 3
# fetch_ttfx.jl keeps GitHub's list of open pull requests in meta, refreshed every two
# hours; it is used rather than listing them again from the 60 requests an hour GitHub
# allows the host. A list older than this is fetched here instead.
const PULLS_MAX_AGE = Hour(6)
const PR_COLS = ["title", "author", "draft", "pr_head_sha", "base_ref", "build", "job_uuid", "job_state", "build_created_at",
                 "finished_at", "web_url", "head_commit", "head_version", "head_llvm", "base_commit", "base_version", "base_llvm",
                 "blocks", "verdict", "n_benchmarks", "n_regressions", "n_improvements", "n_instr_changed", "n_errors", "geomean",
                 "categories", "benchmarks", "errors"]

# The open pull requests by number, and when the list was taken
function open_pulls(db)
    at_row = query(db, "SELECT value FROM meta WHERE key = 'ttfx:open_prs_at'")
    list = query(db, "SELECT value FROM meta WHERE key = 'ttfx:open_prs'")
    if !isempty(at_row) && !isempty(list)
        listed_at = Store.parse_upstream(String(at_row[1].value))
        if now(UTC) - listed_at < PULLS_MAX_AGE
            return Dict{Int,Any}(Int(p.number) => p for p in JSON3.read(String(list[1].value))), listed_at
        end
    end
    listed_at = now(UTC)
    return github_open_pulls(), listed_at
end

# Finished runtime benchmark jobs of julia-pr builds created since `since`, by pull
# request number, newest first
function pr_jobs(since::DateTime)
    jobs = Dict{Int,Vector{Any}}()
    buildkite_pages("organizations/$BUILDKITE_ORG/pipelines/$PR_PIPELINE/builds", ["created_from" => Store.iso(since)]; max_pages=50) do builds, _
        for build in builds
            pr = get(build, :pull_request, nothing)
            n = pr === nothing ? nothing : tryparse(Int, string(get(pr, :id, "")))
            n === nothing && continue
            for job in get(build, :jobs, [])
                get(job, :type, nothing) == "script" || continue
                name = get(job, :name, nothing)
                (name === nothing || match(RTB_JOB, String(name)) === nothing) && continue
                String(get(job, :state, "")) in FINISHED_STATES || continue
                push!(get!(jobs, n, Any[]), (build, job))
            end
        end
    end
    for list in values(jobs)
        sort!(list; by=x -> -x[1].number)
    end
    return jobs
end

geomean(xs) = isempty(xs) ? nothing : exp(sum(log, xs) / length(xs))

"""
    pr_row(pull, build, job, compare, meta) -> Tuple

A pull request's row (in the order of `["pr_number"; PR_COLS]`) from its GitHub listing
(or the summary of it kept in meta), the julia-pr build and job, and the job's
compare.json and results-meta.json.
"""
function pr_row(pull, build, job, compare, meta)
    arm(label) = getin(meta, :arms, Symbol(String(get(compare, label, String(label)))))
    head, base = arm(:head), arm(:base)
    benchmarks = collect(get(compare, :benchmarks, []))
    categories = collect(get(compare, :categories, []))
    errors = Dict("errors" => something(get(compare, :errors, nothing), Dict()), "failures" => something(get(compare, :failures, nothing), []))
    nreg = count(b -> get(b, :verdict, "") == "regression", benchmarks)
    nimp = count(b -> get(b, :verdict, "") == "improvement", benchmarks)
    sreg = count(c -> get(c, :verdict, "") == "regression", categories)
    verdict = nreg + sreg > 0 ? "regression" : nimp > 0 ? "improvement" : "same"
    ratios = [Float64(b.ratio) for b in benchmarks if get(b, :ratio, nothing) isa Number && b.ratio > 0]
    blocks = maxornothing([get(b, :blocks, nothing) for b in benchmarks])
    return (Int(pull.number), str(get(pull, :title, nothing)), str(getin(pull, :user, :login)), get(pull, :draft, false) === true ? 1 : 0,
            str(getin(pull, :head, :sha)), str(getin(pull, :base, :ref)),
            Int(build.number), String(job.id), String(job.state), Store.iso(Store.parse_upstream(String(build.created_at))),
            at(get(job, :finished_at, nothing)), miss(get(job, :web_url, nothing)),
            isempty(str(getin(head, :commit))) ? String(build.commit) : str(getin(head, :commit)), str(getin(head, :version)),
            str(getin(head, :llvm)), str(getin(base, :commit)), str(getin(base, :version)), str(getin(base, :llvm)),
            miss(blocks), verdict, length(benchmarks), nreg, nimp, count(b -> get(b, :instr_changed, false) === true, benchmarks),
            length(keys(errors["errors"])), miss(geomean(ratios)),
            JSON3.write(categories), JSON3.write(benchmarks), JSON3.write(errors))
end

"""
    write_prs!(db, rows; open_numbers=nothing, listed_at=nothing)

Upsert `pr_row`s, and with `open_numbers` delete the rows of pull requests not among
them whose build is older than `listed_at`, when the list was taken.
"""
function write_prs!(db, rows; open_numbers=nothing, listed_at=nothing)
    seq = next_seq!(db)
    stmt = upsert_stmt(db, "rtb_prs", ["pr_number"], PR_COLS)
    for r in rows
        upsert!(stmt, (r..., seq))
    end
    if open_numbers !== nothing
        DBInterface.execute(db, "DELETE FROM rtb_prs WHERE pr_number NOT IN (SELECT value FROM json_each(?)) AND build_created_at < ?",
                            (JSON3.write(collect(open_numbers)), Store.iso(listed_at)))
    end
    return length(rows)
end

function refresh_prs!(db)
    existing = Dict(Int(r.pr_number) => String(r.job_uuid) for r in query(db, "SELECT pr_number, job_uuid FROM rtb_prs"))
    pulls, listed_at = open_pulls(db)
    since = now(UTC) - Day(isempty(existing) ? PR_BACKFILL_DAYS : PR_LOOKBACK_DAYS)
    rows = Any[]
    for (n, list) in pr_jobs(since)
        pull = get(pulls, n, nothing)
        pull === nothing && continue
        for (build, job) in list
            # The newest job with a comparison is what the row has already
            get(existing, n, "") == String(job.id) && break
            fetched = fetch_job_artifacts(PR_PIPELINE, build, job, ("compare.json", "results-meta.json"))
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
        write_prs!(db, rows; open_numbers=keys(pulls), listed_at)
        # Titles and heads move on between jobs
        stmt = DBInterface.prepare(db, "UPDATE rtb_prs SET title = ?1, author = ?2, draft = ?3, pr_head_sha = ?4, base_ref = ?5, change_seq = ?6 " *
                                       "WHERE pr_number = ?7 AND (title IS NOT ?1 OR author IS NOT ?2 OR draft IS NOT ?3 OR pr_head_sha IS NOT ?4 OR base_ref IS NOT ?5)")
        seq = next_seq!(db)
        for r in query(db, "SELECT pr_number FROM rtb_prs")
            p = get(pulls, Int(r.pr_number), nothing)
            p === nothing && continue
            DBInterface.execute(stmt, (str(get(p, :title, nothing)), str(getin(p, :user, :login)), get(p, :draft, false) === true ? 1 : 0,
                                       str(getin(p, :head, :sha)), str(getin(p, :base, :ref)), seq, Int(r.pr_number)))
        end
    end
    @info "Open pull requests with a runtime benchmark comparison" updated=length(rows) total=query(db, "SELECT count(*) AS n FROM rtb_prs")[1].n
    return length(rows)
end

# --- the backfill ----------------------------------------------------------------

# Master commits measured on manyjulias builds before CI ran the job, on another machine:
# a series of their own, never compared with julia-ci's rows. The machine running it
# publishes them as one gzipped file of JSON lines, a release asset of julia-ci-benchmarks,
# one line per commit: sha, date (its merge time, ISO 8601 UTC), subject, rc (bench.jl's
# exit code), meta (results-meta.json) and results (results.json, each record's samples
# cut to their minimum, which is all summarize_records reads).
const BACKFILL_PIPELINE = "manyjulias"
const BACKFILL_RELEASE = "https://api.github.com/repos/JuliaCI/julia-ci-benchmarks/releases/tags/backfill"
const BACKFILL_ASSET = "runtime-backfill.jsonl.gz"

backfill_job_uuid(sha) = "$BACKFILL_PIPELINE-$sha"

"""
    backfill_row(sha, results, meta; rc, date, subject) -> Dict

One backfilled commit's row, as `job_row` makes it for a julia-ci job. `date` is the
commit's merge time (ISO 8601 UTC); without it, the build's commit date (to the minute).
nothing when neither is known.
"""
function backfill_row(sha, results, meta; rc, date=nothing, subject="")
    head = getin(meta, :arms, :head)
    if date === nothing
        m = match(r"^(\d{4}-\d\d-\d\d) (\d\d:\d\d)", str(getin(head, :date)))
        m === nothing && return nothing
        date = Store.iso(DateTime("$(m[1])T$(m[2]):00"))
    end
    benchmarks = results === nothing ? Dict{String,Dict{String,Any}}() : summarize_records(results, "head")
    failures = getin(meta, :failures)
    started = getin(meta, :started)
    duration = num(getin(meta, :duration_s))
    return Dict{String,Any}(
        "job_uuid" => backfill_job_uuid(sha), "build" => 0, "kind" => "master",
        "state" => rc == 0 ? "passed" : "failed", "build_created_at" => date, "commit_sha" => sha,
        "message" => length(subject) > 80 ? first(subject, 77) * "..." : subject,
        "version" => str(getin(head, :version)), "llvm" => str(getin(head, :llvm)), "cpu_target" => str(getin(head, :cpu_target)),
        "agent" => str(getin(meta, :machine, :hostname)), "machine" => str(getin(meta, :machine, :cpu)),
        "suite_commit" => str(getin(meta, :suite_commit)),
        "counters_backend" => results === nothing || isempty(results) ? "" : str(get(results[1], :counters_backend, nothing)),
        "blocks" => getin(meta, :settings, :blocks), "threads" => getin(meta, :settings, :threads),
        "n_benchmarks" => length(benchmarks), "n_failed" => count(b -> b["status"] != "ok", values(benchmarks)),
        "failures" => failures === nothing ? nothing : JSON3.write(failures), "duration_s" => duration,
        "started_at" => started === nothing ? missing : Store.iso(DateTime(String(started))),
        "finished_at" => started === nothing || duration === nothing ? missing :
                         Store.iso(DateTime(String(started)) + Second(round(Int, duration))),
        "web_url" => nothing, "has_results" => results === nothing ? 0 : 1,
        "benchmarks" => benchmarks, "_results" => nothing, "_meta" => nothing)
end

# The rows of a bundle's commits that `known` (job_uuids) does not have
function backfill_bundle_rows(io, known)
    rows = Any[]
    for line in eachline(GzipDecompressorStream(io))
        isempty(line) && continue
        e = JSON3.read(line)
        sha = String(e.sha)
        backfill_job_uuid(sha) in known && continue
        row = backfill_row(sha, get(e, :results, nothing), get(e, :meta, nothing); rc=Int(get(e, :rc, 1)),
                           date=(d = get(e, :date, nothing); d === nothing ? nothing : Store.iso(Store.parse_upstream(String(d)))),
                           subject=String(something(get(e, :subject, nothing), "")))
        row === nothing || push!(rows, row)
    end
    return rows
end

"""
    refresh_backfill!(db) -> Int

Import the commits of the published backfill bundle that the database does not have yet.
The asset's update time is kept in meta, so an unchanged bundle costs one request.
"""
function refresh_backfill!(db)
    resp = http_get_retry(BACKFILL_RELEASE, github_headers())
    resp.status == 404 && return 0
    resp.status == 200 || error("looking up the backfill release failed: HTTP $(resp.status)")
    assets = JSON3.read(resp.body).assets
    i = findfirst(a -> String(a.name) == BACKFILL_ASSET, assets)
    i === nothing && return 0
    asset = assets[i]
    stamp = "$(asset.id) $(asset.updated_at)"
    seen = query(db, "SELECT value FROM meta WHERE key = 'runtime_backfill_asset'")
    !isempty(seen) && seen[1].value == stamp && return 0
    dl = http_get_retry(String(asset.browser_download_url), ["User-Agent" => "julia-ci-timing-fetcher"])
    dl.status == 200 || error("downloading the backfill bundle failed: HTTP $(dl.status)")
    known = Set(String(r.job_uuid) for r in query(db, "SELECT job_uuid FROM rtb_jobs WHERE pipeline = ?", (BACKFILL_PIPELINE,)))
    rows = backfill_bundle_rows(IOBuffer(dl.body), known)
    transaction(db) do
        write_rows!(db, rows; pipeline=BACKFILL_PIPELINE, raw=false)
        Store.setmeta!(db, "runtime_backfill_asset", stamp)
    end
    @info "Backfilled commits" new=length(rows)
    return length(rows)
end

# --- main ------------------------------------------------------------------------

function run!(db)
    existing = query(db, "SELECT job_uuid, build FROM rtb_jobs")
    known = Set(String(r.job_uuid) for r in existing)
    rows = fetch_new_rows(known, unique(Int[r.build for r in existing]))
    @info "New runtime benchmark rows" count=length(rows)
    transaction(db) do
        write_rows!(db, rows)
    end
    # GitHub's quota or a julia-pr listing failing leaves the rows as they were rather
    # than failing the master results with it
    try
        refresh_prs!(db)
    catch e
        @error "Updating the pull request comparisons failed" exception=(e, catch_backtrace())
    end
    n = 0
    try
        n = refresh_backfill!(db)
    catch e
        @error "Importing the backfill failed" exception=(e, catch_backtrace())
    end
    return length(rows) + n
end

function main(args=ARGS)
    db = open_db(Store.db_path(args); create=false)
    source_run(db, "runtime") do
        run!(db)
    end
    close(db)
    return 0
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
