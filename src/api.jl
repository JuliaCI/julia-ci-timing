# The site's API: the shapes of db/Render.jl served on demand from the
# database, with a time window where the data is large, so the browser
# loads what it shows instead of the whole extract. db/serve.jl is the
# command line entry point.
#
# GET /api/ lists every route with its parameters, from the route table
# below that the router matches against.
#
# Every response but /api/status and /api/ready carries an ETag from its
# source's change sequence (the last commit that changed that source's
# rows) and the build, so a browser's revalidation costs nothing until an
# ingest changes that source or a deploy changes what a route renders.
# Bodies are rendered once per (request, sequence) and kept gzipped in a
# bounded cache. Requests take a query-only connection from a small
# pool, so a slow render (all of timing, a big benchmark group) does not
# hold up the rest.
#
# --site DIR and --data DIR serve the static site and the extracts too, for
# local development; on the host Caddy does that.

# Part of every ETag: the deployed commit (BUILD_COMMIT is written into the
# image by deploy.yml), or a hash of the renderer's source on a checkout,
# so a deploy that changes a route's shape is not answered from a browser's
# cache with 304 until that source's data happens to change. Read when the
# package loads, not when it is precompiled.
const BUILD_ID = Ref("")
function build_id()
    f = joinpath(dirname(@__DIR__), "BUILD_COMMIT")
    return isfile(f) ? first(strip(read(f, String)), 12) : string(hash(read(joinpath(dirname(@__DIR__), "db", "Render.jl"))); base=16)
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
    ready::Bool                                    # the warm-up has finished
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

const SOURCES = ("timing", "benchmarks", "pkgeval", "ttfx", "packages", "agents")

function status(db)
    return Dict("change_seq" => Store.current_seq(db),
                "source_seq" => Dict(source => Store.source_seq(db, source) for source in SOURCES),
                "generated_at" => Dict(source => Render.generated_at(db, source) for source in SOURCES),
                "server_time" => Store.iso_now())
end

function bench_metric(params)
    metric = get(params, "metric", "time")
    haskey(Render.BENCH_METRICS, metric) || throw(BadRequest("metric must be one of " * join(sort(collect(keys(Render.BENCH_METRICS))), ", ")))
    return metric
end

# An API route: its path under /api/ (`<name>` marks a path argument), the
# query parameters it reads, what it returns, and the handler rendering it
# from the database, the path arguments and the parameters. GET /api/ lists
# this table, so the index is the router and cannot drift from it.
struct Route
    path::String
    params::Vector{Pair{String,String}}
    description::String
    handler::Function
end

const SINCE = "since" => "start of the window: YYYY-MM-DD, or YYYY-MM-DDTHH:MM:SSZ. Omitted means all history, so pass it."
const CLIENT = "client" => "whose downloads rank the packages: user (default), ci or all"

function days_param(params, default)
    n = cursor(params, "days")
    return n == 0 ? default : min(n, 366)
end

function client_param(params)
    client = get(params, "client", "user")
    client in ("user", "ci", "all") || throw(BadRequest("client must be user, ci or all"))
    return client
end

const ROUTES = [
    Route("status", [], "The global change sequence, each source's sequence (the ETag of its routes, which moves when an ingest changes its rows), when each source's last successful ingest finished, and the server's time. Never cached, so it is the cheap thing to poll.",
          (db, _, _) -> status(db)),
    Route("ready", [], "Whether this server has finished warming up: 200 once the routes the site loads on landing are rendered into its cache, 503 before. A deploy starts the new server beside the old one and switches to it when this answers 200.",
          (db, _, _) -> Dict("ready" => true)),
    Route("timing/runs",
          [SINCE, "until" => "end of the window (exclusive), same forms as since",
           "changed_since" => "a change_seq from an earlier response: only the builds changed since then, for an incremental refresh"],
          "CI job runs by job name, newest first, plus a map of their builds (commit, author, message, date) and coverage per commit. The window is on the build's creation time; 30 days is about 0.2 MB gzipped.",
          (db, _, p) -> Render.timing(db; since=instant(p, "since"), until=instant(p, "until"), changed_since=cursor(p, "changed_since"))),
    Route("timing/builds", [SINCE],
          "Master builds newest first: state, wall time, job count and time, and the queue wait of their jobs (median, max, total). Builds before September 2026 have no timestamps and are left out.",
          (db, _, p) -> Render.timing_builds(db; since=instant(p, "since"))),
    Route("benchmarks/summary", ["metric" => "time (default), gctime, memory or allocs"],
          "Geometric mean of every Nanosoldier benchmark group on every daily report, and the reports' dates and commits.",
          (db, _, p) -> Render.bench_summary(db; metric=bench_metric(p))),
    Route("benchmarks/groups/<group>", [SINCE, "metric" => "time (default), gctime, memory or allocs"],
          "Every benchmark of one group on every daily report in the window, for the minimum and mean estimates. The group names are the keys of benchmarks/summary.",
          (db, a, p) -> a[1] in Render.bench_groups(db) ? Render.bench_group(db, a[1]; since=instant(p, "since"), metric=bench_metric(p)) : nothing),
    Route("benchmarks/verdicts", [SINCE],
          "Nanosoldier's own regressions and improvements on each daily report: benchmark, time and memory ratios and tolerances.",
          (db, _, p) -> Render.bench_verdicts(db; since=instant(p, "since"))),
    Route("pkgeval/summary", [],
          "PkgEval daily reports: date, Julia version, commit and the counts of ok, fail, crash, skip and kill.",
          (db, _, _) -> Render.pkgeval(db)),
    Route("pkgeval/packages", ["q" => "a name prefix, case-insensitive"],
          "Up to 25 package names starting with q, for looking a package up.",
          (db, _, p) -> Render.pkgeval_packages(db, get(p, "q", ""))),
    Route("pkgeval/package/<name>", [],
          "One package's status, reason, version and test duration on every daily report with package results.",
          (db, a, _) -> Render.pkgeval_package(db, a[1])),
    Route("pkgeval/reasons", ["path" => "a report as YYYY-MM/DD; the newest by default"],
          "How many packages failed each way (status and reason) on one report.",
          (db, _, p) -> begin
              path = get(p, "path", "")
              (isempty(path) || occursin(r"^\d{4}-\d{2}/\d{2}$", path)) || throw(BadRequest("path must be YYYY-MM/DD"))
              Render.pkgeval_reasons(db, path)
          end),
    Route("pkgeval/popular", ["days" => "download window in days, 30 by default", CLIENT, "limit" => "packages to list, 50 by default, at most 500"],
          "The most downloaded packages not passing the newest report, with their download rank, reason and how long each has been failing; the download-weighted pass rate; the packages newly broken since the report before.",
          (db, _, p) -> begin
              limit = cursor(p, "limit")
              Render.pkgeval_popular(db; days=days_param(p, 30), limit=limit == 0 ? 50 : min(limit, 500), client=client_param(p))
          end),
    Route("ttfx/summary", [SINCE],
          "TTFX on every master build: per task, the precompile, load, run and warm seconds (and load, run and warm with the GC off), plus failed tasks.",
          (db, _, p) -> Render.ttfx(db; since=instant(p, "since"))),
    Route("ttfx/prs", [],
          "Open julia pull requests ranked by their latest TTFX comparison (head against the master build of the merge-base), best first: the job's verdict and robust improvements and regressions, the suite geomean ratio per metric and block, and the flagged tasks. score is the estimated ratio of the suite's total time: the precompile, load, run and warm ratios weighted by each metric's time on master, taking per metric the block nearest no change (1 when the blocks disagree); below 1 is faster. outdated means the pull request has moved on since the job's commit. stack is null unless the pull request targets another one's branch: then the job measured it against that branch, own_score is that comparison, and score and stack.suite estimate the whole stack against master by multiplying in the suite geomeans of the pull requests below it (stack.parents, nearest first; complete false when one has no comparison, which leaves score null; exact false when a lower one has moved on since this job's base). ci is the state of the newest julia-pr build of the pull request's current head (null until looked up, state none when it has no build).",
          (db, _, _) -> Render.ttfx_prs(db)),
    Route("downloads/summary", [],
          "Package server requests per day (total, user, CI), by Julia version and release stage, with Julia release tags.",
          (db, _, _) -> Render.downloads(db)),
    Route("downloads/packages", ["q" => "a name prefix, case-insensitive"],
          "Up to 25 General registry package names starting with q.",
          (db, _, p) -> Render.download_packages(db, get(p, "q", ""))),
    Route("downloads/package/<name>", [],
          "One registered package's successful requests per day, user and CI.",
          (db, a, _) -> Render.download_package(db, a[1])),
    Route("downloads/top", ["days" => "window in days, 7 by default", CLIENT],
          "The 50 most requested packages over the window.",
          (db, _, p) -> Render.download_top(db; days=days_param(p, 7), client=client_param(p))),
    Route("agents/latest", [],
          "Every Buildkite agent seen in the last year: host, queue, OS, state, first and last seen, and its job if it has one now.",
          (db, _, _) -> Render.agents_latest(db)),
    Route("agents/snapshots", [SINCE],
          "The connected agents at every ingest, as a list of snapshots.",
          (db, _, p) -> Render.agent_snapshots(db; since=instant(p, "since"))),
    Route("agents/backlog", [SINCE],
          "Per agent pool (queue, os, arch): how many julia-pr and julia-ci jobs were waiting for an agent and how many were running, sampled every step_s seconds from start (the jobs are kept for 60 days), with the longest current wait in seconds at each sample, the agent slots seen for the pool in the last 30 days (capped per host at the most jobs the host was seen running at once), its hosts, and shared_with, the other pools that draw on the same hosts' slots; host_slots has the most jobs each host was seen running at once; by_pipeline has the same series for julia-ci (master) and julia-pr (pull requests) jobs separately.",
          (db, _, p) -> Render.pool_backlog(db; since=instant(p, "since"))),
    Route("agents/usage", ["days" => "window in days before the latest agents snapshot, 7 by default, at most 60 (the jobs are kept for 60 days)"],
          "Agent time spent on julia-pr and julia-ci jobs that finished in the window, from start to finish: seconds and job count per pipeline, job name, pool (queue, os, arch) and final state, busiest first. Jobs still running are left out.",
          (db, _, p) -> Render.worker_time(db; days=min(days_param(p, 7), 60))),
    Route("commits", ["before" => "the first_at of the last commit already listed, to page back", "limit" => "commits per page, 100 by default, at most 500"],
          "Master commits newest first, one row per commit: first build time, latest build state, author, subject, and whether a daily benchmark or PkgEval report ran on it.",
          (db, _, p) -> begin
              limit = cursor(p, "limit")
              Render.commit_list(db; before=instant(p, "before"), limit=limit == 0 ? 100 : min(limit, 500))
          end),
    Route("commit/<ref>", [],
          "Everything recorded for one master commit: its builds, each job's time and state against the previous commit's build, TTFX against the previous run, the first benchmark and PkgEval daily reports that include it, and coverage. ref is a SHA prefix of 7 to 40 hex digits or a PR number; a ref matching several commits returns them under matches.",
          (db, a, _) -> begin
              ref = lowercase(a[1])
              occursin(r"^(\d{1,6}|[0-9a-f]{7,40})$", ref) || throw(BadRequest("ref must be a PR number or a commit SHA of at least 7 characters"))
              Render.commit(db, ref)
          end),
]

# The path arguments when `segments` match the route's path, else nothing
function match_route(route, segments)
    parts = split(route.path, '/')
    length(parts) == length(segments) || return nothing
    args = String[]
    for (part, seg) in zip(parts, segments)
        if startswith(part, "<")
            push!(args, seg)
        elseif part != seg
            return nothing
        end
    end
    return args
end

# GET /api/: what the API serves and where the rest of the data is
function api_index()
    routes = [OrderedDict("path" => "/api/" * r.path, "params" => OrderedDict(r.params), "description" => r.description) for r in ROUTES]
    return OrderedDict(
        "about" => "The API behind perf.julialang.org: Julia's CI timing, Nanosoldier benchmarks, PkgEval, TTFX, package downloads and Buildkite agents, from one SQLite database refreshed every half hour. All routes are GET and answer JSON, gzipped when asked (curl --compressed), with an ETag for revalidation. It is the site's own interface, so shapes can change; the database schema is the stable reference.",
        "guide" => "https://perf.julialang.org/llms.txt",
        "sql" => "https://perf.julialang.org/db/ (Datasette, read-only SQL; 2 s and 5000 rows per query)",
        "snapshot" => "https://perf.julialang.org/data/ci-timing.sqlite.gz (the whole database, taken once a week, about 220 MB)",
        "schema" => "https://github.com/JuliaCI/julia-ci-timing/blob/main/db/schema.sql",
        "health" => "https://perf.julialang.org/healthz",
        "routes" => routes)
end

# path segments after /api/ and the query parameters -> the rendered value
function render(db, segments, params)
    isempty(segments) && return api_index()
    for route in ROUTES
        args = match_route(route, segments)
        args === nothing || return route.handler(db, args, params)
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

not_found() = json_response(404, Dict("error" => "not found", "routes" => "/api/ lists every route"))

# A request target under /api/ -> its URI, path segments and query parameters
function split_target(target)
    uri = HTTP.URI(target)
    segments = String[String(x) for x in split(uri.path, '/'; keepempty=false)]
    popfirst!(segments)   # "api"
    params = Dict{String,String}(String(k) => String(v) for (k, v) in HTTP.queryparams(uri))
    return uri, segments, params
end

function api(s::Server, req::HTTP.Request)
    uri, segments, params = split_target(req.target)
    # A deploy and the proxy's health checks ask; answered before anything
    # touches the database or the cache
    if segments == ["ready"]
        return HTTP.Response(s.ready ? 200 : 503, ["Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store"],
                             JSON3.write(Dict("ready" => s.ready)))
    end
    # An ingest that changes no rows still moves its finish time, so no
    # sequence can validate this one
    if segments == ["status"]
        return HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store"],
                             JSON3.write(withdb(status, s)))
    end
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
    headers(n) = ["Content-Type" => "application/json; charset=utf-8", "ETag" => "W/\"$n-$(BUILD_ID[])\"",
                  "Cache-Control" => "no-cache", "Vary" => "Accept-Encoding"]
    # A browser revalidates per URL, so the window is implied by the match;
    # checked before any render, so a current browser is answered at once
    # even while the cache fills after a restart
    HTTP.header(req, "If-None-Match", "") == "W/\"$served-$(BUILD_ID[])\"" && return HTTP.Response(304, headers(served))
    if hit !== nothing
        body = hit[2]
    elseif cacheable
        r = render_cached!(s, key, segments, params, seq)
        r === nothing && return not_found()
        # A render already under way when this request came may be older
        served, body = r
    else
        value = withdb(db -> render(db, segments, params), s)
        value === nothing && return not_found()
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
const SITE_PATHS = Set(["index.html", "favicon.svg", "site.webmanifest", "llms.txt", "assets", "data",
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

# What the Overview and the Commit tab ask for on landing, under the query
# strings the browser sends (site/assets/app.js: apiGet keeps its
# parameters' order, windows are UTC days)
function landing_targets()
    day(n) = Dates.format(Date(now(UTC)) - Day(n), dateformat"yyyy-mm-dd")
    return ["/api/timing/runs?since=$(day(30))", "/api/timing/builds?since=$(day(7))",
            "/api/pkgeval/summary", "/api/benchmarks/summary", "/api/ttfx/summary", "/api/ttfx/prs", "/api/downloads/summary",
            "/api/agents/latest", "/api/pkgeval/reasons", "/api/downloads/top?days=7&client=user",
            "/api/pkgeval/popular?days=30&client=user&limit=50", "/api/commits?limit=100"]
end

# One request of every other route, with arguments the database has
function other_targets(db)
    since = Dates.format(Date(now(UTC)) - Day(7), dateformat"yyyy-mm-dd")
    latest = Render.commit_list(db; limit=1)["commits"]
    groups = Render.bench_groups(db)
    return ["/api/timing/runs?since=$since&changed_since=1", "/api/benchmarks/verdicts?since=$since",
            "/api/pkgeval/packages?q=A", "/api/pkgeval/package/Example", "/api/downloads/packages?q=A", "/api/downloads/package/Example",
            "/api/agents/snapshots?since=$since", "/api/agents/backlog?since=$since", "/api/agents/usage?days=7",
            "/api/commit/$(isempty(latest) ? "0000000" : latest[1]["commit"])",
            (isempty(groups) ? String[] : ["/api/benchmarks/groups/$(groups[1])?since=$since"])...]
end

# Right after start, on another thread, so a page loading meanwhile is
# served slowly rather than refused: render what the site asks for on
# landing into the cache, and run the other routes once without caching
# them, so nothing is left to compile for a visitor. The package is
# precompiled with the same requests (src/precompile.jl), which leaves
# this the time of the renders themselves.
function warm_up(s::Server)
    t = @elapsed begin
        for target in landing_targets()
            handle(s, HTTP.Request("GET", target, ["Accept-Encoding" => "gzip"]))
        end
        withdb(s) do db
            for target in other_targets(db)
                _, segments, params = split_target(target)
                gzip(Vector{UInt8}(JSON3.write(render(db, segments, params))))
            end
        end
    end
    @info "warmed up" seconds=round(t; digits=1)
end

function main(args)
    opts = parse_args(args)
    pool = Channel{SQLite.DB}(POOL_SIZE)
    foreach(_ -> put!(pool, open_readonly(opts["db"])), 1:POOL_SIZE)
    s = Server(pool, ReentrantLock(), Dict(), String[], 0, opts["site"], opts["data"], 0.0, Dict(), false)
    server = HTTP.serve!(req -> handle(s, req), opts["host"], opts["port"])
    @info "serving" host=opts["host"] port=opts["port"] db=opts["db"] site=opts["site"] data=opts["data"]
    Threads.@spawn begin
        try
            warm_up(s)
        catch e
            @error "warm-up failed" exception=(e, catch_backtrace())
        end
        s.ready = true
        refresh_loop(s)
    end
    wait(server)
end
