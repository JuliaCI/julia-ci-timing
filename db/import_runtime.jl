#!/usr/bin/env julia
# Import runtime benchmark results measured outside CI: the backfill of master commits
# from manyjulias builds, made before the Runtime benchmarks job ran on julia-ci. It runs
# on another machine, so its rows (pipeline 'manyjulias') form a series of their own,
# which the Runtime tab shows apart from CI's. fetch_runtime.jl imports the published
# bundle by itself; this is for a bundle or a results directory at hand.
#
#   julia --project db/import_runtime.jl --db ci-timing.sqlite [--commits commits.tsv] [--replace] SOURCE
#
# SOURCE is a bundle (runtime-backfill.jsonl.gz, see fetch_runtime.jl) or a directory with
# one directory per commit, named by its full SHA, holding what bench.jl of
# julia-ci-benchmarks wrote for that build alone (results.json, results-meta.json) and
# `done`, whose first word is bench.jl's exit code; a directory without `done` is still
# running and is skipped. For a directory, --commits is a tab-separated file of
# `sha  committer date (ISO 8601 UTC)  subject` lines, such as
#
#   TZ=UTC git log --first-parent --date=iso-strict-local --format='%H%x09%cd%x09%s' master
#
# which gives each commit its merge time and subject; without it, the build's own commit
# date (to the minute) is used and the subject is left empty. A commit already imported
# is skipped unless --replace.

include(joinpath(dirname(@__DIR__), "fetch_runtime.jl"))

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

function directory_rows(dir, commits, known)
    rows = Any[]
    for sha in readdir(dir)
        occursin(r"^[0-9a-f]{40}$", sha) && backfill_job_uuid(sha) ∉ known || continue
        d = joinpath(dir, sha)
        isfile(joinpath(d, "done")) || continue
        readjson(f) = (p = joinpath(d, f); isfile(p) ? JSON3.read(read(p, String)) : nothing)
        rc = something(tryparse(Int, first(split(read(joinpath(d, "done"), String) * " 1"))), 1)
        date, subject = get(commits, sha, (nothing, ""))
        row = backfill_row(sha, readjson("results.json"), readjson("results-meta.json"); rc, date, subject)
        row === nothing || push!(rows, row)
    end
    return rows
end

function import_main(args)
    flag(name) = (i = findfirst(==(name), args); i === nothing ? nothing : args[i+1])
    source = args[end]
    ispath(source) || error("usage: import_runtime.jl --db DB [--commits FILE] [--replace] SOURCE")
    db = open_db(Store.db_path(args); create=false)
    known = "--replace" in args ? Set{String}() :
            Set(String(r.job_uuid) for r in query(db, "SELECT job_uuid FROM rtb_jobs WHERE pipeline = ?", (BACKFILL_PIPELINE,)))
    rows = isdir(source) ? directory_rows(source, read_commits(flag("--commits")), known) :
           open(io -> backfill_bundle_rows(io, known), source)
    # As a run of the source, so its change sequence (the routes' ETag) moves
    source_run(db, "runtime") do
        for batch in Iterators.partition(rows, 200)
            transaction(db) do
                write_rows!(db, collect(batch); pipeline=BACKFILL_PIPELINE, raw=false)
            end
        end
        length(rows)
    end
    @info "Imported" commits=length(rows)
    close(db)
end

abspath(PROGRAM_FILE) == (@__FILE__) && import_main(ARGS)
