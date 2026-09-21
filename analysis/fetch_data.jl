#!/usr/bin/env julia
# Download the site's data extracts into a local data/ directory, for the
# analysis scripts (BenchHistory.jl, tools/inspect-bench.mjs) and anything
# else that reads the files, now that they are rendered on the host rather
# than committed.
#
#   julia --project analysis/fetch_data.jl [--base URL] [--out DIR] [--only timing,benchmarks,...]
#
# Defaults: the live site, the repository's data/, every source. Files are
# only downloaded when the server reports a change (If-None-Match against
# the copy's ETag file), so re-running is cheap.

using Pkg
Pkg.activate(dirname(@__DIR__); io=devnull)

using HTTP, JSON3, CodecZlib

const SOURCES = Dict(
    "timing" => ["timing_summary.json.gz"],
    "benchmarks" => ["benchmark_summary.json.gz"],   # plus one file per group, listed from the summary
    "pkgeval" => ["pkgeval_summary.json.gz"],
    "ttfx" => ["ttfx_summary.json.gz"],
    "packages" => ["packages_downloads_summary.json.gz"],
    "agents" => ["agents/latest.json"],               # plus the month files it implies
)

function parse_args(args)
    opts = Dict{String,Any}("base" => "https://perf.julialang.org", "out" => joinpath(dirname(@__DIR__), "data"),
                            "only" => sort(collect(keys(SOURCES))))
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--base"
            opts["base"] = rstrip(args[i+1], '/'); i += 2
        elseif a == "--out"
            opts["out"] = args[i+1]; i += 2
        elseif a == "--only"
            opts["only"] = split(args[i+1], ','); i += 2
        else
            error("unknown argument $a")
        end
    end
    return opts
end

# Fetch one file unless the copy is current; returns the local path or nothing
function fetch_file(base, out, rel)
    dest = joinpath(out, rel)
    etag_file = dest * ".etag"
    headers = isfile(dest) && isfile(etag_file) ? ["If-None-Match" => read(etag_file, String)] : Pair{String,String}[]
    r = HTTP.get("$base/data/$rel", headers; status_exception=false)
    if r.status == 304
        println("  current  $rel")
        return dest
    elseif r.status == 404
        println("  missing  $rel")
        return nothing
    end
    r.status == 200 || error("GET $base/data/$rel: HTTP $(r.status)")
    mkpath(dirname(dest))
    write(dest, r.body)
    etag = HTTP.header(r, "ETag", "")
    isempty(etag) ? rm(etag_file; force=true) : write(etag_file, etag)
    println("  fetched  $rel ($(round(length(r.body) / 1024; digits=1)) KB)")
    return dest
end

load_gz(path) = JSON3.read(transcode(GzipDecompressor, read(path)))

function main(args)
    opts = parse_args(args)
    base, out = opts["base"], opts["out"]
    println("$base -> $out")
    for source in opts["only"]
        haskey(SOURCES, source) || error("unknown source $source; one of $(join(sort(collect(keys(SOURCES))), ", "))")
        println(source)
        for rel in SOURCES[source]
            path = fetch_file(base, out, rel)
            path === nothing && continue
            if source == "benchmarks"
                groups = sort!(unique(String[String(g) for r in load_gz(path).reports for g in keys(get(r, :by_group, Dict()))]))
                foreach(g -> fetch_file(base, out, "benchmarks/$g.json.gz"), groups)
            elseif source == "agents"
                # Month files from the earliest first_seen to now, as the site does
                latest = JSON3.read(read(path))
                earliest = minimum((String(get(a, :first_seen, ""))[1:7] for a in values(latest.agents) if !isempty(get(a, :first_seen, ""))); init="9999-99")
                month = min(earliest, String(latest.generated_at)[1:7])
                while month <= String(latest.generated_at)[1:7]
                    fetch_file(base, out, "agents/history-$month.ndjson")
                    y, m = parse(Int, month[1:4]), parse(Int, month[6:7])
                    month = m == 12 ? "$(y + 1)-01" : "$y-" * lpad(m + 1, 2, '0')
                end
            end
        end
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
