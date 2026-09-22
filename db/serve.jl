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
#   /api/pkgeval/popular?days=&client=&limit=   the most downloaded packages not passing the latest report
#   /api/ttfx/summary?since=                    ttfx_summary.json.gz, windowed
#   /api/downloads/summary                      packages_downloads_summary.json.gz
#   /api/downloads/packages?q=                  registry names starting with q
#   /api/downloads/package/<name>               one package's daily requests
#   /api/downloads/top?days=&client=            most requested packages
#   /api/agents/latest                          agents/latest.json
#   /api/agents/snapshots?since=                the history-*.ndjson lines, as an array
#   /api/commits?before=&limit=                 master commits newest first, one row per commit
#   /api/commit/<ref>                           one commit across every source; ref is a SHA
#                                               prefix (7 to 40 hex) or a PR number
#
# Every response carries an ETag from its source's change sequence (the
# last commit that changed that source's rows; /api/status uses the global
# one) and the build, so a browser's revalidation costs nothing until an
# ingest changes that source or a deploy changes what a route renders.
# Bodies are rendered once per (request, sequence) and kept gzipped in a
# bounded cache. Requests take a query-only connection from a small
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

# Part of every ETag: the deployed commit (BUILD_COMMIT is written into the
# image by deploy.yml), or a hash of the renderer's source on a checkout,
# so a deploy that changes a route's shape is not answered from a browser's
# cache with 304 until that source's data happens to change
const BUILD_ID = let f = joinpath(dirname(@__DIR__), "BUILD_COMMIT")
    isfile(f) ? first(strip(read(f, String)), 12) : string(hash(read(joinpath(@__DIR__, "Render.jl"))); base=16)
end

const CACHE_MAX_ENTRIES = 32
const CACHE_MAX_BYTES = 64 * 1024 * 1024
const POOL_SIZE = 4
# The refresher's pass interval, how long it may go without finishing a pass
# before stale entries are rendered inline again, and how long an entry
# nobody asks for is kept up to date
const REFRESH_INTERVAL_S = 20
const REFRESH_HEALTHY_S = 120
const REFRESH_KEEP_S = 24 * 3600

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

# A rendered body and what it takes to render it again
mutable struct CacheEntry
    seq::Int                      # the route's change sequence it was rendered at
    body::Vector{UInt8}           # gzipped
    segments::Vector{String}
    params::Dict{String,String}
    hit_at::Float64               # last served, for dropping what nobody asks for
end

mutable struct Server
    pool::Channel{SQLite.DB}
    lock::ReentrantLock                            # the cache
    cache::Dict{String,CacheEntry}
    cache_order::Vector{String}
    cache_bytes::Int
    site::Union{Nothing,String}
    data::Union{Nothing,String}
    refreshed_at::Float64                          # the refresher's last finished pass
    inflight::Dict{String,Base.Event}              # renders under way, by cache key (under `lock`)
end

function open_readonly(path)
    isfile(path) || error("database $path does not exist")
    db = SQLite.DB(path)
    # A reader of a WAL database; never a writer, even by accident
    SQLite.execute(db, "PRAGMA query_only = 1")
    # WAL recovery after a restore or crash, or the ingest's schema
    # migration on open, would otherwise answer SQLITE_BUSY at once
    SQLite.busy_timeout(db, 5000)
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

# The source each route family reads, for its ETag; nothing means global
const ROUTE_SOURCES = Dict("timing" => "timing", "benchmarks" => "benchmarks", "pkgeval" => "pkgeval",
                           "ttfx" => "ttfx", "downloads" => "packages", "agents" => "agents")

function route_seq(s::Server, segments)
    source = isempty(segments) ? nothing : get(ROUTE_SOURCES, segments[1], nothing)
    return source === nothing ? change_seq(s) : withdb(db -> Store.source_seq(db, source), s)
end

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
    elseif segments == ["pkgeval", "popular"]
        days = cursor(params, "days")
        limit = cursor(params, "limit")
        client = get(params, "client", "user")
        client in ("user", "ci", "all") || throw(BadRequest("client must be user, ci or all"))
        return Render.pkgeval_popular(db; days=days == 0 ? 30 : min(days, 366), limit=limit == 0 ? 50 : min(limit, 500), client)
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
    elseif segments == ["commits"]
        limit = cursor(params, "limit")
        return Render.commit_list(db; before=instant(params, "before"), limit=limit == 0 ? 100 : min(limit, 500))
    elseif length(segments) == 2 && segments[1] == "commit"
        ref = lowercase(segments[2])
        occursin(r"^(\d{1,6}|[0-9a-f]{7,40})$", ref) || throw(BadRequest("ref must be a PR number or a commit SHA of at least 7 characters"))
        return Render.commit(db, ref)
    end
    return nothing
end

# --- cache -------------------------------------------------------------------

# The entry for a key at whatever sequence it was rendered, marking it used
function cache_get(s::Server, key)
    lock(s.lock) do
        e = get(s.cache, key, nothing)
        e === nothing && return nothing
        e.hit_at = time()
        return (e.seq, e.body)
    end
end

# A new entry counts as used now; a render of an existing one (the
# refresher's) keeps its last use, so what nobody asks for still ages out
function cache_put!(s::Server, key, seq, body, segments, params)
    lock(s.lock) do
        old = get(s.cache, key, nothing)
        hit_at = old === nothing ? time() : old.hit_at
        if old !== nothing
            s.cache_bytes -= length(old.body)
            filter!(!=(key), s.cache_order)
        end
        s.cache[key] = CacheEntry(seq, body, segments, params, hit_at)
        push!(s.cache_order, key)
        s.cache_bytes += length(body)
        while (length(s.cache_order) > CACHE_MAX_ENTRIES || s.cache_bytes > CACHE_MAX_BYTES) && length(s.cache_order) > 1
            evicted = popfirst!(s.cache_order)
            s.cache_bytes -= length(s.cache[evicted].body)
            delete!(s.cache, evicted)
        end
    end
end

function cache_delete!(s::Server, key)
    lock(s.lock) do
        e = pop!(s.cache, key, nothing)
        e === nothing && return
        s.cache_bytes -= length(e.body)
        filter!(!=(key), s.cache_order)
    end
end

# Render a key into the cache, once at a time: a request, the warm-up and the
# refresher asking for the same key while it renders wait for that render
# rather than starting another (after a restart they would all compile and
# run the same heavy query side by side). Returns (seq, body), or nothing
# when the route has no such resource.
function render_cached!(s::Server, key, segments, params, seq)
    while true
        ev, mine = lock(s.lock) do
            e = get(s.inflight, key, nothing)
            e === nothing || return (e, false)
            e = s.inflight[key] = Base.Event()
            return (e, true)
        end
        if mine
            try
                value = withdb(db -> render(db, segments, params), s)
                value === nothing && return nothing
                body = gzip(Vector{UInt8}(JSON3.write(value)))
                cache_put!(s, key, seq, body, segments, params)
                return (seq, body)
            finally
                lock(() -> delete!(s.inflight, key), s.lock)
                notify(ev)
            end
        end
        wait(ev)
        hit = cache_get(s, key)
        # The other render found nothing or failed: try it here
        hit === nothing || return hit
    end
end

# An ingest moves a source's sequence and so outdates the entries that read
# it; rendering them again here, rather than for the next visitor, means
# nobody waits on a render the cache has already been asked for (pkgeval's
# popular list takes seconds). Until the new body is in, the old one is
# served with its own ETag.
function refresh_stale!(s::Server)
    entries = lock(s.lock) do
        [(k, e.seq, e.segments, e.params, e.hit_at) for (k, e) in s.cache]
    end
    for (key, old, segments, params, hit_at) in entries
        if time() - hit_at > REFRESH_KEEP_S
            cache_delete!(s, key)
            continue
        end
        seq = route_seq(s, segments)
        seq == old && continue
        render_cached!(s, key, segments, params, seq) === nothing && cache_delete!(s, key)
    end
end

function refresh_loop(s::Server)
    while true
        try
            refresh_stale!(s)
            s.refreshed_at = time()
        catch e
            @error "cache refresh failed" exception=(e, catch_backtrace())
        end
        sleep(REFRESH_INTERVAL_S)
    end
end

refresher_healthy(s::Server) = time() - s.refreshed_at < REFRESH_HEALTHY_S

gzip(bytes) = transcode(GzipCompressor, bytes)

cache_key(segments, query) = "/api/" * join(segments, "/") * "?" * query

# --- responses ---------------------------------------------------------------

json_response(status, value) = HTTP.Response(status, ["Content-Type" => "application/json; charset=utf-8"], JSON3.write(value))

accepts_gzip(req) = occursin("gzip", HTTP.header(req, "Accept-Encoding", ""))

function api(s::Server, req::HTTP.Request)
    uri = HTTP.URI(req.target)
    segments = String[String(x) for x in split(uri.path, '/'; keepempty=false)]
    popfirst!(segments)   # "api"
    params = Dict{String,String}(String(k) => String(v) for (k, v) in HTTP.queryparams(uri))
    seq = route_seq(s, segments)
    # Incremental refreshes are small and their cursors differ per client;
    # the cache is for the windows and extracts everyone asks for
    cacheable = !haskey(params, "changed_since")
    key = cache_key(segments, uri.query)
    hit = cacheable ? cache_get(s, key) : nothing
    # An outdated entry is served while the refresher renders it again,
    # unless the refresher has stopped
    hit !== nothing && hit[1] != seq && !refresher_healthy(s) && (hit = nothing)
    served = hit === nothing ? seq : hit[1]
    headers(n) = ["Content-Type" => "application/json; charset=utf-8", "ETag" => "W/\"$n-$BUILD_ID\"",
                  "Cache-Control" => "no-cache", "Vary" => "Accept-Encoding"]
    # A browser revalidates per URL, so the window is implied by the match;
    # checked before any render, so a current browser is answered at once
    # even while the cache fills after a restart
    HTTP.header(req, "If-None-Match", "") == "W/\"$served-$BUILD_ID\"" && return HTTP.Response(304, headers(served))
    if hit !== nothing
        body = hit[2]
    elseif cacheable
        r = render_cached!(s, key, segments, params, seq)
        r === nothing && return json_response(404, Dict("error" => "not found"))
        # A render already under way when this request came may be older
        served, body = r
    else
        value = withdb(db -> render(db, segments, params), s)
        value === nothing && return json_response(404, Dict("error" => "not found"))
        body = gzip(Vector{UInt8}(JSON3.write(value)))
    end
    if accepts_gzip(req)
        return HTTP.Response(200, push!(headers(served), "Content-Encoding" => "gzip"), body)
    end
    return HTTP.Response(200, headers(served), transcode(GzipDecompressor, body))
end

const CONTENT_TYPES = Dict(".html" => "text/html; charset=utf-8", ".js" => "text/javascript; charset=utf-8",
                           ".css" => "text/css; charset=utf-8", ".json" => "application/json; charset=utf-8",
                           ".gz" => "application/gzip", ".svg" => "image/svg+xml", ".ndjson" => "application/x-ndjson",
                           ".png" => "image/png", ".ico" => "image/x-icon", ".txt" => "text/plain; charset=utf-8",
                           ".webmanifest" => "application/manifest+json")

# Development only: what Caddy serves on the host, and nothing else of a
# checkout (--site is usually the repository, which also holds .git and
# Terraform state): index.html, favicon.svg, assets/, the tab directories
# and data/. Paths are resolved before the containment check, so a
# symbolic link cannot lead outside either.
const SITE_PATHS = Set(["index.html", "favicon.svg", "site.webmanifest", "assets", "data",
                        "overview", "commit", "diff", "history", "timing", "builds", "commits", "workers", "ttfx", "downloads", "pkgeval"])

function static(root, path; allowed=SITE_PATHS)
    rel = HTTP.unescapeuri(path)
    occursin('\0', rel) && return HTTP.Response(400, "bad path")
    parts = String[String(p) for p in split(rel, '/'; keepempty=false)]
    isempty(parts) && (parts = ["index.html"])
    ((allowed === nothing || parts[1] in allowed) && all(p -> p != "." && p != "..", parts)) || return HTTP.Response(404, "not found")
    file = joinpath(root, parts...)
    isdir(file) && (file = joinpath(file, "index.html"))
    isfile(file) || return HTTP.Response(404, "not found")
    startswith(realpath(file), realpath(root) * "/") || return HTTP.Response(404, "not found")
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
            return static(s.data, path[6:end]; allowed=nothing)   # the export directory holds only extracts
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

# Right after start, on another thread, so a page loading meanwhile is
# served slowly rather than refused: render what the Overview and the
# Commit tab ask for on landing into the cache, under the query strings the
# browser sends (site/assets/app.js: apiGet keeps its parameters' order,
# windows are UTC days), and compile the other routes by rendering them once.
function warm_up(s::Server)
    t = @elapsed begin
        day(n) = Dates.format(Date(now(UTC)) - Day(n), dateformat"yyyy-mm-dd")
        cached = [
            "timing/runs" => "since=$(day(30))", "timing/builds" => "since=$(day(7))",
            "pkgeval/summary" => "", "benchmarks/summary" => "", "ttfx/summary" => "", "downloads/summary" => "",
            "agents/latest" => "", "pkgeval/reasons" => "", "downloads/top" => "days=7&client=user",
            "pkgeval/popular" => "days=30&client=user&limit=50", "commits" => "limit=100"]
        for (route, query) in cached
            segments = String.(split(route, '/'))
            params = Dict{String,String}(String(k) => String(v) for (k, v) in HTTP.queryparams(query))
            render_cached!(s, cache_key(segments, query), segments, params, route_seq(s, segments))
        end
        withdb(s) do db
            since = day(7)
            latest = Render.commit_list(db; limit=1)["commits"]
            compile_only = Any[
                (["timing", "runs"], Dict("since" => since, "changed_since" => "1")),
                (["benchmarks", "verdicts"], Dict("since" => since)),
                (["pkgeval", "packages"], Dict("q" => "A")),
                (["pkgeval", "package", "Example"], Dict()),
                (["downloads", "packages"], Dict("q" => "A")),
                (["downloads", "package", "Example"], Dict()),
                (["agents", "snapshots"], Dict("since" => since)),
                (["commit", isempty(latest) ? "0000000" : latest[1]["commit"]], Dict())]
            for (segments, params) in compile_only
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
    s = Server(pool, ReentrantLock(), Dict(), String[], 0, opts["site"], opts["data"], 0.0, Dict())
    server = HTTP.serve!(req -> handle(s, req), opts["host"], opts["port"])
    @info "serving" host=opts["host"] port=opts["port"] db=opts["db"] site=opts["site"] data=opts["data"]
    Threads.@spawn begin
        try
            warm_up(s)
        catch e
            @error "warm-up failed" exception=(e, catch_backtrace())
        end
        refresh_loop(s)
    end
    wait(server)
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
