#!/usr/bin/env julia
# Render the files the site reads (data/*.json.gz, data/benchmarks/*.json.gz,
# data/agents/*) from the database, in the shapes the fetchers write today.
#
#   julia --project db/export.jl --out DIR [--db PATH] [--only timing,benchmarks,...]
#
# The shapes come from db/Render.jl, which db/serve.jl also serves on
# demand. Files are written to a temporary name and renamed into place, so a
# reader never sees a partial file. db/compare.jl compares two exports.
#
# A source whose sequence has not moved since its last export, by the same
# code, is skipped, so its files keep the generated_at of the last run that
# changed its rows. So is one exported within the last hour: the site
# reads the API, and rendering timing alone takes about 20 s on the host,
# which every run would pay. --force renders every source anyway.

using Pkg
Pkg.activate(dirname(@__DIR__); io=devnull)

# The package has the store and the renderer precompiled
using CITiming.Store, CITiming.Render
using JSON3, CodecZlib, DataStructures, Dates

const SOURCES = ["timing", "benchmarks", "pkgeval", "ttfx", "sizes", "packages", "agents"]
# A little under an hour, so a run that comes an hour later is not skipped by a few seconds
const EXPORT_INTERVAL = Minute(55)

function parse_args(args)
    opts = Dict{String,Any}("db" => Store.db_path(args), "out" => nothing, "only" => SOURCES, "force" => false)
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--db"
            opts["db"] = args[i+1]; i += 2
        elseif a == "--out"
            opts["out"] = args[i+1]; i += 2
        elseif a == "--only"
            opts["only"] = split(args[i+1], ','); i += 2
        elseif a == "--force"
            opts["force"] = true; i += 1
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
    remove_others(joinpath(out, "benchmarks"), Set("$grp.json.gz" for grp in groups), r"\.json\.gz$")
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

function export_sizes(db, out)
    payload = Render.sizes(db; metrics=["all"])
    write_gz_json(joinpath(out, "sizes_summary.json.gz"), payload)
    @info "sizes" commits=length(payload["commits"])
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
    remove_others(dir, Set("history-$month.ndjson" for month in keys(by_month)), r"^history-.*\.ndjson$")
    @info "agents" agents=length(latest["agents"]) snapshots=length(snapshots) months=length(by_month)
end

# Files of a group or month the export no longer writes would otherwise be
# served for good
function remove_others(dir, keep, pattern)
    isdir(dir) || return
    for f in readdir(dir)
        (occursin(pattern, f) && f ∉ keep) && rm(joinpath(dir, f))
    end
end

function export_health(db, out)
    write_atomic(joinpath(out, "health.json")) do io
        JSON3.write(io, Render.health(db))
        println(io)
    end
end

const EXPORTERS = Dict("timing" => export_timing, "benchmarks" => export_benchmarks, "pkgeval" => export_pkgeval,
                       "ttfx" => export_ttfx, "sizes" => export_sizes, "packages" => export_packages, "agents" => export_agents)

function main(args)
    opts = parse_args(args)
    db = open_db(opts["db"]; create=false)
    mkpath(opts["out"])
    # Each source's sequence at its last export, kept beside the files. New
    # code can change the shapes, so it renders everything again.
    seqs_path = joinpath(opts["out"], ".export_seqs.json")
    code = string(hash(read(joinpath(@__DIR__, "Render.jl")), hash(read(@__FILE__))); base=16)
    previous = isfile(seqs_path) ? JSON3.read(read(seqs_path, String)) : nothing
    exported = Dict{String,Int}()
    exported_at = Dict{String,String}()
    if previous !== nothing && get(previous, :code, "") == code
        for (k, v) in previous.seqs
            exported[String(k)] = v
        end
        for (k, v) in get(previous, :at, Dict())
            exported_at[String(k)] = String(v)
        end
    end
    now_utc = now(UTC)
    # One source failing to render leaves its files as they were; the others
    # and the health file are still written
    failed = String[]
    for source in String.(opts["only"])
        seq = Store.source_seq(db, source)
        if !opts["force"] && get(exported, source, -1) == seq
            @info "skipped $source: unchanged since its last export"
            continue
        end
        last_at = get(exported_at, source, nothing)
        if !opts["force"] && haskey(exported, source) && last_at !== nothing &&
           now_utc - DateTime(last_at, dateformat"yyyy-mm-ddTHH:MM:SS") < EXPORT_INTERVAL
            @info "skipped $source: exported at $last_at"
            continue
        end
        try
            t = @elapsed EXPORTERS[source](db, opts["out"])
            exported[source] = seq
            exported_at[source] = Dates.format(now_utc, dateformat"yyyy-mm-ddTHH:MM:SS")
            @info "exported $source" seconds=round(t; digits=1)
        catch e
            @error "export of $source failed" exception=(e, catch_backtrace())
            push!(failed, source)
        end
    end
    write_atomic(io -> JSON3.write(io, Dict("code" => code, "seqs" => exported, "at" => exported_at)), seqs_path)
    export_health(db, opts["out"])
    close(db)
    return isempty(failed) ? 0 : 1
end

abspath(PROGRAM_FILE) == (@__FILE__) && exit(main(ARGS))
