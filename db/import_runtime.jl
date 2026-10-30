#!/usr/bin/env julia
# Import runtime benchmark results measured outside CI: the backfill of master commits
# from manyjulias builds, made before the Runtime benchmarks job ran on julia-ci. It runs
# on another machine, so its rows (pipeline 'manyjulias') form a series of their own,
# which the Runtime tab shows apart from CI's.
#
#   julia --project db/import_runtime.jl --db ci-timing.sqlite [--commits commits.tsv] [--replace] RESULTS
#
# RESULTS has one directory per commit, named by its full SHA, holding what bench.jl of
# julia-ci-benchmarks wrote for that build alone (results.json, results-meta.json) and
# `done`, whose first word is bench.jl's exit code; a directory without `done` is still
# running and is skipped. --commits is a tab-separated file of `sha  committer date
# (ISO 8601 UTC)  subject` lines, such as
#
#   TZ=UTC git log --first-parent --date=iso-strict-local --format='%H%x09%cd%x09%s' master
#
# which gives each commit its merge time and subject; without it, the build's own commit
# date (to the minute) is used and the subject is left empty. A commit already imported
# is skipped unless --replace.

using Dates
include(joinpath(dirname(@__DIR__), "fetch_runtime.jl"))

const BACKFILL_PIPELINE = "manyjulias"

function read_commits(path)
    out = Dict{String,Tuple{String,String}}()
    path === nothing && return out
    for line in eachline(path)
        parts = split(line, '\t'; limit=3)
        length(parts) == 3 || continue
        out[String(parts[1])] = (Store.iso(Store.parse_upstream(String(parts[2]))), String(parts[3]))
    end
    return out
end

# "2026-10-30 11:25 UTC", as Base.GIT_VERSION_INFO.date_string has it
function build_date(s)
    m = match(r"^(\d{4}-\d\d-\d\d) (\d\d:\d\d)", s)
    return m === nothing ? nothing : Store.iso(DateTime("$(m[1])T$(m[2]):00"))
end

"""
    backfill_row(sha, dir, commits) -> Dict or nothing

One backfilled commit's row, as `job_row` makes it for a julia-ci job, from the
directory bench.jl wrote. nothing when the run has not finished or its date is unknown.
"""
function backfill_row(sha, dir, commits)
    isfile(joinpath(dir, "done")) || return nothing
    rc = tryparse(Int, first(split(read(joinpath(dir, "done"), String) * " 1")))
    readjson(f) = (p = joinpath(dir, f); isfile(p) ? JSON3.read(read(p, String)) : nothing)
    results, meta = readjson("results.json"), readjson("results-meta.json")
    head = getin(meta, :arms, :head)
    date, subject = get(commits, sha) do
        (build_date(str(getin(head, :date))), "")
    end
    date === nothing && return nothing
    benchmarks = results === nothing ? Dict{String,Dict{String,Any}}() : summarize_records(results, "head")
    failures = getin(meta, :failures)
    started = getin(meta, :started)
    duration = num(getin(meta, :duration_s))
    finished = started === nothing || duration === nothing ? missing :
               Store.iso(DateTime(String(started)) + Second(round(Int, duration)))
    message = length(subject) > 80 ? first(subject, 77) * "..." : subject
    return Dict{String,Any}(
        "job_uuid" => "$BACKFILL_PIPELINE-$sha", "build" => 0, "kind" => "master",
        "state" => rc == 0 ? "passed" : "failed", "build_created_at" => date, "commit_sha" => sha, "message" => message,
        "version" => str(getin(head, :version)), "llvm" => str(getin(head, :llvm)), "cpu_target" => str(getin(head, :cpu_target)),
        "agent" => str(getin(meta, :machine, :hostname)), "machine" => str(getin(meta, :machine, :cpu)),
        "suite_commit" => str(getin(meta, :suite_commit)),
        "counters_backend" => results === nothing || isempty(results) ? "" : str(get(results[1], :counters_backend, nothing)),
        "blocks" => getin(meta, :settings, :blocks), "threads" => getin(meta, :settings, :threads),
        "n_benchmarks" => length(benchmarks), "n_failed" => count(b -> b["status"] != "ok", values(benchmarks)),
        "failures" => failures === nothing ? nothing : JSON3.write(failures), "duration_s" => duration,
        "started_at" => started === nothing ? missing : Store.iso(DateTime(String(started))), "finished_at" => finished,
        "web_url" => nothing, "has_results" => results === nothing ? 0 : 1,
        "benchmarks" => benchmarks, "_results" => nothing, "_meta" => nothing)
end

function import_main(args)
    flag(name) = (i = findfirst(==(name), args); i === nothing ? nothing : args[i+1])
    dir = args[end]
    isdir(dir) || error("usage: import_runtime.jl --db DB [--commits FILE] [--replace] RESULTS")
    commits = read_commits(flag("--commits"))
    replace_existing = "--replace" in args
    db = open_db(Store.db_path(args); create=false)
    known = Set(String(r.job_uuid) for r in query(db, "SELECT job_uuid FROM rtb_jobs WHERE pipeline = ?", (BACKFILL_PIPELINE,)))
    shas = filter(s -> occursin(r"^[0-9a-f]{40}$", s) && (replace_existing || "$BACKFILL_PIPELINE-$s" ∉ known), readdir(dir))
    n = 0
    # As a run of the source, so its change sequence (the routes' ETag) moves
    source_run(db, "runtime") do
        for batch in Iterators.partition(shas, 200)
            rows = filter(!isnothing, [backfill_row(s, joinpath(dir, s), commits) for s in batch])
            transaction(db) do
                write_rows!(db, rows; pipeline=BACKFILL_PIPELINE, raw=false)
            end
            n += length(rows)
        end
        n
    end
    @info "Imported" commits=n skipped=length(readdir(dir)) - n
    close(db)
end

abspath(PROGRAM_FILE) == (@__FILE__) && import_main(ARGS)
