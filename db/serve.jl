#!/usr/bin/env julia
# The site's API: the shapes of db/Render.jl served on demand from the
# database, with a time window where the data is large, so the browser
# loads what it shows instead of the whole extract.
#
#   julia --project db/serve.jl [--db PATH] [--host 127.0.0.1] [--port 8002] [--site DIR] [--data DIR]
#
# Routes (all GET, JSON):
#   /api/status                                 change_seq, per-source generated_at
#   /api/timing/runs?since=&until=&changed_since=  jobs -> recent runs (window on the
#                                               build's created_at; changed_since is
#                                               the change_seq cursor of a refresh)
#   /api/timing/builds?since=                   builds with wall time and queue waits
#   /api/benchmarks/summary?metric=             benchmark_summary.json.gz; metric is time
#                                               (default), gctime, memory or allocs
#   /api/benchmarks/groups/<group>?since=&metric=  benchmarks/<group>.json.gz, windowed
#   /api/benchmarks/verdicts?since=             Nanosoldier's regressions and improvements
#   /api/pkgeval/summary                        pkgeval_summary.json.gz
#   /api/pkgeval/packages?q=                    package names starting with q
#   /api/pkgeval/package/<name>                 one package's status on every report
#   /api/pkgeval/reasons?path=                  status and reason counts of a report (latest by default)
#   /api/ttfx/summary?since=                    ttfx_summary.json.gz, windowed
#   /api/downloads/summary                      packages_downloads_summary.json.gz
#   /api/downloads/packages?q=                  registry names starting with q
#   /api/downloads/package/<name>               one package's daily requests
#   /api/downloads/top?days=&client=            most requested packages
#   /api/agents/latest                          agents/latest.json
#   /api/agents/snapshots?since=                the history-*.ndjson lines, as an array
#
# Every response carries an ETag from the database's change sequence, so a
# browser's revalidation costs nothing until an ingest changes something.
# Bodies are rendered once per (request, change sequence) and kept gzipped
# in a bounded cache. Requests take a query-only connection from a small
# pool, so a slow render (all of timing, a big benchmark group) does not
# hold up the rest.
#
# --site DIR and --data DIR serve the static site and the extracts too, for
# local development; on the host Caddy does that.

using Pkg
Pkg.activate(dirname(@__DIR__); io=devnull)

include(joinpath(@__DIR__, "Store.jl"))
using .Store
include(joinpath(@__DIR__, "Render.jl"))
using .Render
using HTTP, SQLite, JSON3, CodecZlib, Dates

const CACHE_MAX_ENTRIES = 32
const CACHE_MAX_BYTES = 64 * 1024 * 1024
const POOL_SIZE = 4

function parse_args(args)
    opts = Dict{String,Any}("db" => Store.db_path(args), "host" => "127.0.0.1", "port" => 8002, "site" => nothing, "data" => nothing)
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--db"
            opts["db"] = args[i+1]; i += 2
        elseif a == "--host"
            opts["host"] = args[i+1]; i += 2
        elseif a == "--port"
            opts["port"] = parse(Int, args[i+1]); i += 2
        elseif a == "--site"
            opts["site"] = abspath(args[i+1]); i += 2
        elseif a == "--data"
            opts["data"] = abspath(args[i+1]); i += 2
        else
            error("unknown argument $a")
        end
    end
    return opts
end

# --- database ----------------------------------------------------------------

mutable struct Server
    pool::Channel{SQLite.DB}
    lock::ReentrantLock                            # the cache
    cache::Dict{String,Tuple{Int,Vector{UInt8}}}   # key => (change_seq, gzipped body)
    cache_order::Vector{String}
    cache_bytes::Int
    site::Union{Nothing,String}
    data::Union{Nothing,String}
end

function open_readonly(path)
    isfile(path) || error("database $path does not exist")
    db = SQLite.DB(path)
    # A reader of a WAL database; never a writer, even by accident
    SQLite.execute(db, "PRAGMA query_only = 1")
    return db
end

function withdb(f, s::Server)
    db = take!(s.pool)
    try
        return f(db)
    finally
        put!(s.pool, db)
    end
end

change_seq(s::Server) = withdb(db -> Store.current_seq(db), s)

# --- parameters --------------------------------------------------------------

const ISO_INSTANT = r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2})?Z)?$"

struct BadRequest <: Exception
    msg::String
end

# A window bound is a date or an instant; anything else is refused rather
# than compared as text
function instant(params, key)
    v = get(params, key, "")
    isempty(v) && return ""
    occursin(ISO_INSTANT, v) || throw(BadRequest("$key must be YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ"))
    return v
end

function cursor(params, key)
    v = get(params, key, "")
    isempty(v) && return 0
    n = tryparse(Int, v)
    (n === nothing || n < 0) && throw(BadRequest("$key must be a non-negative integer"))
    return n
end

# --- routes ------------------------------------------------------------------

function status(db)
    sources = Dict(source => Render.generated_at(db, source) for source in ("timing", "benchmarks", "pkgeval", "ttfx", "packages", "agents"))
    return Dict("change_seq" => Store.current_seq(db), "generated_at" => sources, "server_time" => Store.iso_now())
end

function bench_metric(params)
    metric = get(params, "metric", "time")
    haskey(Render.BENCH_METRICS, metric) || throw(BadRequest("metric must be one of " * join(sort(collect(keys(Render.BENCH_METRICS))), ", ")))
    return metric
end

# path segments after /api/ and the query parameters -> the rendered value
function render(db, segments, params)
    if segments == ["status"]
        return status(db)
    elseif segments == ["timing", "runs"]
        return Render.timing(db; since=instant(params, "since"), until=instant(params, "until"),
                             changed_since=cursor(params, "changed_since"))
    elseif segments == ["timing", "builds"]
        return Render.timing_builds(db; since=instant(params, "since"))
    elseif segments == ["benchmarks", "summary"]
        return Render.bench_summary(db; metric=bench_metric(params))
    elseif length(segments) == 3 && segments[1:2] == ["benchmarks", "groups"]
        grp = segments[3]
        grp in Render.bench_groups(db) || return nothing
        return Render.bench_group(db, grp; since=instant(params, "since"), metric=bench_metric(params))
    elseif segments == ["benchmarks", "verdicts"]
        return Render.bench_verdicts(db; since=instant(params, "since"))
    elseif segments == ["pkgeval", "summary"]
        return Render.pkgeval(db)
    elseif segments == ["pkgeval", "packages"]
        return Render.pkgeval_packages(db, get(params, "q", ""))
    elseif length(segments) == 3 && segments[1:2] == ["pkgeval", "package"]
        return Render.pkgeval_package(db, segments[3])
    elseif segments == ["pkgeval", "reasons"]
        path = get(params, "path", "")
        (isempty(path) || occursin(r"^\d{4}-\d{2}/\d{2}$", path)) || throw(BadRequest("path must be YYYY-MM/DD"))
        return Render.pkgeval_reasons(db, path)
    elseif segments == ["ttfx", "summary"]
        return Render.ttfx(db; since=instant(params, "since"))
    elseif segments == ["downloads", "summary"]
        return Render.downloads(db)
    elseif segments == ["downloads", "packages"]
        return Render.download_packages(db, get(params, "q", ""))
    elseif length(segments) == 3 && segments[1:2] == ["downloads", "package"]
        return Render.download_package(db, segments[3])
    elseif segments == ["downloads", "top"]
        days = cursor(params, "days")
        client = get(params, "client", "user")
        client in ("user", "ci", "all") || throw(BadRequest("client must be user, ci or all"))
        return Render.download_top(db; days=days == 0 ? 7 : min(days, 366), client)
    elseif segments == ["agents", "latest"]
        return Render.agents_latest(db)
    elseif segments == ["agents", "snapshots"]
        return Render.agent_snapshots(db; since=instant(params, "since"))
    end
    return nothing
end

# --- cache -------------------------------------------------------------------

function cache_get(s::Server, key, seq)
    lock(s.lock) do
        hit = get(s.cache, key, nothing)
        return hit !== nothing && hit[1] == seq ? hit[2] : nothing
    end
end

function cache_put!(s::Server, key, seq, body)
    lock(s.lock) do
        old = get(s.cache, key, nothing)
        old === nothing || (s.cache_bytes -= length(old[2]); filter!(!=(key), s.cache_order))
        s.cache[key] = (seq, body)
        push!(s.cache_order, key)
        s.cache_bytes += length(body)
        while (length(s.cache_order) > CACHE_MAX_ENTRIES || s.cache_bytes > CACHE_MAX_BYTES) && length(s.cache_order) > 1
            evicted = popfirst!(s.cache_order)
            s.cache_bytes -= length(s.cache[evicted][2])
            delete!(s.cache, evicted)
        end
    end
end

gzip(bytes) = transcode(GzipCompressor, bytes)

# --- responses ---------------------------------------------------------------

json_response(status, value) = HTTP.Response(status, ["Content-Type" => "application/json; charset=utf-8"], JSON3.write(value))

accepts_gzip(req) = occursin("gzip", HTTP.header(req, "Accept-Encoding", ""))

function api(s::Server, req::HTTP.Request)
    uri = HTTP.URI(req.target)
    segments = String[String(x) for x in split(uri.path, '/'; keepempty=false)]
    popfirst!(segments)   # "api"
    params = Dict{String,String}(String(k) => String(v) for (k, v) in HTTP.queryparams(uri))
    seq = change_seq(s)
    etag = "W/\"$seq\""
    headers = ["Content-Type" => "application/json; charset=utf-8", "ETag" => etag,
               "Cache-Control" => "no-cache", "Vary" => "Accept-Encoding"]
    # A browser revalidates per URL, so the window is implied by the match
    HTTP.header(req, "If-None-Match", "") == etag && return HTTP.Response(304, headers)
    # Incremental refreshes are small and their cursors differ per client;
    # the cache is for the windows and extracts everyone asks for
    cacheable = !haskey(params, "changed_since")
    key = uri.path * "?" * uri.query
    body = cacheable ? cache_get(s, key, seq) : nothing
    if body === nothing
        value = withdb(db -> render(db, segments, params), s)
        value === nothing && return json_response(404, Dict("error" => "not found"))
        body = gzip(Vector{UInt8}(JSON3.write(value)))
        cacheable && cache_put!(s, key, seq, body)
    end
    if accepts_gzip(req)
        push!(headers, "Content-Encoding" => "gzip")
        return HTTP.Response(200, headers, body)
    end
    return HTTP.Response(200, headers, transcode(GzipDecompressor, body))
end

const CONTENT_TYPES = Dict(".html" => "text/html; charset=utf-8", ".js" => "text/javascript; charset=utf-8",
                           ".css" => "text/css; charset=utf-8", ".json" => "application/json; charset=utf-8",
                           ".gz" => "application/gzip", ".svg" => "image/svg+xml", ".ndjson" => "application/x-ndjson",
                           ".png" => "image/png", ".ico" => "image/x-icon", ".txt" => "text/plain; charset=utf-8")

# Development only: index.html, assets/ and the tab directories from --site,
# data/ from --data, like Caddy on the host
function static(root, path)
    rel = HTTP.unescapeuri(path)
    (occursin("..", rel) || occursin('\0', rel)) && return HTTP.Response(400, "bad path")
    file = joinpath(root, lstrip(rel, '/'))
    isdir(file) && (file = joinpath(file, "index.html"))
    isfile(file) || return HTTP.Response(404, "not found")
    ctype = get(CONTENT_TYPES, lowercase(splitext(file)[2]), "application/octet-stream")
    return HTTP.Response(200, ["Content-Type" => ctype, "Cache-Control" => "no-cache"], read(file))
end

function handle(s::Server, req::HTTP.Request)
    path = HTTP.URI(req.target).path
    try
        if startswith(path, "/api/")
            return api(s, req)
        elseif path == "/healthz"
            return json_response(200, withdb(Render.health, s))
        elseif s.data !== nothing && startswith(path, "/data/")
            return static(s.data, path[7:end])
        elseif s.site !== nothing
            return static(s.site, path)
        end
        return HTTP.Response(404, "not found")
    catch e
        e isa BadRequest && return json_response(400, Dict("error" => e.msg))
        @error "request failed" target=req.target exception=(e, catch_backtrace())
        return json_response(500, Dict("error" => "internal error"))
    end
end

# Compile every route before listening, so the first visitors do not wait
function warm_up(s::Server)
    t = @elapsed begin
        since = Dates.format(Date(now(UTC)) - Day(7), dateformat"yyyy-mm-dd")
        withdb(s) do db
            for (segments, params) in (
                    (["status"], Dict()),
                    (["timing", "runs"], Dict("since" => since)),
                    (["timing", "runs"], Dict("since" => since, "changed_since" => "1")),
                    (["benchmarks", "summary"], Dict()),
                    (["pkgeval", "summary"], Dict()),
                    (["ttfx", "summary"], Dict("since" => since)),
                    (["downloads", "summary"], Dict()),
                    (["agents", "latest"], Dict()),
                    (["agents", "snapshots"], Dict("since" => since)),
                    (["timing", "builds"], Dict("since" => since)),
                    (["benchmarks", "verdicts"], Dict("since" => since)),
                    (["pkgeval", "packages"], Dict("q" => "A")),
                    (["pkgeval", "package", "Example"], Dict()),
                    (["pkgeval", "reasons"], Dict()),
                    (["downloads", "packages"], Dict("q" => "A")),
                    (["downloads", "package", "Example"], Dict()),
                    (["downloads", "top"], Dict("days" => "7")))
                gzip(Vector{UInt8}(JSON3.write(render(db, segments, Dict{String,String}(params)))))
            end
            groups = Render.bench_groups(db)
            isempty(groups) || gzip(Vector{UInt8}(JSON3.write(render(db, ["benchmarks", "groups", groups[1]], Dict("since" => since)))))
        end
    end
    @info "warmed up" seconds=round(t; digits=1)
end

function main(args)
    opts = parse_args(args)
    pool = Channel{SQLite.DB}(POOL_SIZE)
    foreach(_ -> put!(pool, open_readonly(opts["db"])), 1:POOL_SIZE)
    s = Server(pool, ReentrantLock(), Dict(), String[], 0, opts["site"], opts["data"])
    warm_up(s)
    @info "serving" host=opts["host"] port=opts["port"] db=opts["db"] site=opts["site"] data=opts["data"]
    HTTP.serve(req -> handle(s, req), opts["host"], opts["port"])
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
