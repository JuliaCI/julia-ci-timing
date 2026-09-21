#!/usr/bin/env julia
# Render the files the site reads (data/*.json.gz, data/benchmarks/*.json.gz,
# data/agents/*) from the database, in the shapes the fetchers write today.
#
#   julia --project db/export.jl --out DIR [--db PATH] [--only timing,benchmarks,...]
#
# The shapes come from db/Render.jl, which db/serve.jl also serves on
# demand. Files are written to a temporary name and renamed into place, so a
# reader never sees a partial file. db/compare.jl checks an export against
# data/.

using Pkg
Pkg.activate(dirname(@__DIR__); io=devnull)

include(joinpath(@__DIR__, "Store.jl"))
using .Store
include(joinpath(@__DIR__, "Render.jl"))
using .Render
using JSON3, CodecZlib, DataStructures, Dates

const SOURCES = ["timing", "benchmarks", "pkgeval", "ttfx", "packages", "agents"]

function parse_args(args)
    opts = Dict{String,Any}("db" => Store.db_path(args), "out" => nothing, "only" => SOURCES)
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--db"
            opts["db"] = args[i+1]; i += 2
        elseif a == "--out"
            opts["out"] = args[i+1]; i += 2
        elseif a == "--only"
            opts["only"] = split(args[i+1], ','); i += 2
        else
            error("unknown argument $a")
        end
    end
    opts["out"] === nothing && error("--out DIR is required")
    return opts
end

function write_atomic(f, path)
    mkpath(dirname(path))
    tmp = path * ".tmp"
    open(f, tmp, "w")
    mv(tmp, path; force=true)
end

write_gz_json(path, value) = write_atomic(path) do io
    write(io, transcode(GzipCompressor, Vector{UInt8}(JSON3.write(value))))
end

function export_timing(db, out)
    payload = Render.timing_file(db)
    write_gz_json(joinpath(out, "timing_summary.json.gz"), payload)
    @info "timing" jobs=length(payload["jobs"])
end

function export_benchmarks(db, out)
    summary = Render.bench_summary(db)
    write_gz_json(joinpath(out, "benchmark_summary.json.gz"), summary)
    groups = Render.bench_groups(db)
    for grp in groups
        write_gz_json(joinpath(out, "benchmarks", "$grp.json.gz"), Render.bench_group(db, grp))
    end
    @info "benchmarks" reports=length(summary["reports"]) groups=length(groups)
end

function export_pkgeval(db, out)
    payload = Render.pkgeval(db)
    write_gz_json(joinpath(out, "pkgeval_summary.json.gz"), payload)
    @info "pkgeval" reports=length(payload["reports"])
end

function export_ttfx(db, out)
    payload = Render.ttfx(db)
    write_gz_json(joinpath(out, "ttfx_summary.json.gz"), payload)
    @info "ttfx" jobs=length(payload["builds"])
end

function export_packages(db, out)
    payload = Render.downloads(db)
    write_gz_json(joinpath(out, "packages_downloads_summary.json.gz"), payload)
    @info "packages" days=length(payload["series"])
end

function export_agents(db, out)
    dir = joinpath(out, "agents")
    latest = Render.agents_latest(db)
    write_atomic(joinpath(dir, "latest.json")) do io
        JSON3.pretty(io, JSON3.write(latest), JSON3.AlignmentContext(indent=1))
        println(io)
    end
    # Whole months, from the one the retention cutoff falls in
    cutoff = Render.agents_cutoff(latest["generated_at"])
    snapshots = Render.agent_snapshots(db; since=cutoff[1:7] * "-01T00:00:00Z")
    by_month = OrderedDict{String,Vector{Any}}()
    for s in snapshots
        push!(get!(by_month, s["time"][1:7], Any[]), s)
    end
    for (month, ss) in by_month
        write_atomic(joinpath(dir, "history-$month.ndjson")) do io
            for s in ss
                JSON3.write(io, s)
                println(io)
            end
        end
    end
    @info "agents" agents=length(latest["agents"]) snapshots=length(snapshots) months=length(by_month)
end

function export_health(db, out)
    write_atomic(joinpath(out, "health.json")) do io
        JSON3.write(io, Render.health(db))
        println(io)
    end
end

const EXPORTERS = Dict("timing" => export_timing, "benchmarks" => export_benchmarks, "pkgeval" => export_pkgeval,
                       "ttfx" => export_ttfx, "packages" => export_packages, "agents" => export_agents)

function main(args)
    opts = parse_args(args)
    db = open_db(opts["db"]; create=false)
    mkpath(opts["out"])
    for source in opts["only"]
        t = @elapsed EXPORTERS[String(source)](db, opts["out"])
        @info "exported $source" seconds=round(t; digits=1)
    end
    export_health(db, opts["out"])
    close(db)
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
