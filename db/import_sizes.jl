#!/usr/bin/env julia
# Import size measurements made outside fetch_sizes.jl, such as the history of master
# rebuilt from the manyjulias store, which seeds what the nightlies bucket no longer has.
#
#   julia --project db/import_sizes.jl --db ci-timing.sqlite --source manyjulias sizes.tsv.gz
#
# The file (gzipped or not) has one tab-separated line per measured value:
#
#   commit_sha  merged_at  version  kind  key  value
#
# where kind and key are what tools/measure_sizes.jl prints (`metric` and its name, or
# `file` and its path), or kind `subject` with the commit's subject as key (value 0). A commit's rows replace whatever the database has for it. For
# source ci, the commit's first julia-ci build (by its 8-character prefix, which is all
# the builds before September 2026 have) gives merged_at and the build number, as
# fetch_sizes.jl records them; the file's merged_at is used when there is none.

using CodecZlib

include(joinpath(dirname(@__DIR__), "fetch_sizes.jl"))

function read_bundle(path)
    commits = Dict{String,Any}()
    io = open(path)
    endswith(path, ".gz") && (io = GzipDecompressorStream(io))
    for line in eachline(io)
        isempty(line) && continue
        sha, merged_at, version, kind, key, value = split(line, '\t')
        c = get!(commits, sha) do
            (; merged_at=String(merged_at), version=String(version), subject=Ref(""),
               metrics=Dict{String,Int}(), files=Dict{String,Int}())
        end
        if kind == "subject"
            c.subject[] = String(key)
        else
            (kind == "metric" ? c.metrics : c.files)[String(key)] = parse(Int, value)
        end
    end
    close(io)
    # Files measured before `group_files` existed
    return Dict(sha => merge(c, (; files=SizeMeasure.group_files(c.files))) for (sha, c) in commits)
end

function import_main(args)
    i = findfirst(==("--source"), args)
    i === nothing && error("usage: import_sizes.jl --db DB --source NAME [--triplet T] FILE")
    source = args[i+1]
    j = findfirst(==("--triplet"), args)
    triplet = j === nothing ? TRIPLET : args[j+1]
    file = args[end]
    commits = read_bundle(file)
    db = open_db(Store.db_path(args); create=false)
    measured_at = iso_now()
    function ci_build(sha)
        source == "ci" || return nothing
        r = query(db, "SELECT number, created_at, message FROM builds WHERE pipeline = 'julia-ci' AND commit_prefix = ? " *
                      "ORDER BY created_at LIMIT 1", (first(sha, 8),))
        return isempty(r) ? nothing : r[1]
    end
    # As a run of the source, so its change sequence (the routes' ETag) moves
    source_run(db, "sizes") do
        transaction(db) do
            seq = next_seq!(db)
            for (sha, c) in commits
                b = ci_build(sha)
                message = c.subject[]
                row = b === nothing ? (merged_at=c.merged_at, version=c.version, build=missing, message, measured_at) :
                      (merged_at=String(b.created_at), version=c.version, build=Int(b.number), measured_at,
                       message=isempty(message) && b.message != "Scheduled build" ? String(b.message) : message)
                write_measurement!(db, source, triplet, sha, row, c.metrics, c.files; seq)
            end
        end
        length(commits)
    end
    @info "Imported" source triplet commits=length(commits)
    close(db)
end

abspath(PROGRAM_FILE) == (@__FILE__) && import_main(ARGS)
