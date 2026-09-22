#!/usr/bin/env julia
# Fetch aggregated Julia package download counts by date.
# Source announced at:
# https://discourse.julialang.org/t/announcing-package-download-stats/69073
#
# We consume the public rollup and write a compact local summary used by the UI:
#   data/packages_downloads_summary.json.gz

using HTTP
using JSON3
using Dates
using CodecZlib: GzipDecompressor

include(joinpath(@__DIR__, "db", "Store.jl"))
using .Store
using SQLite, DBInterface

const SOURCE_URL =
    "https://julialang-logs.s3.amazonaws.com/public_outputs/current/resource_types_by_date.csv.gz"
const JULIA_VERSIONS_URL =
    "https://julialang-logs.s3.amazonaws.com/public_outputs/current/julia_versions_by_date.csv.gz"
const JULIA_RELEASES_API = "https://api.github.com/repos/JuliaLang/julia/releases?per_page=100"
const PUBLIC_OUTPUTS = "https://julialang-logs.s3.amazonaws.com/public_outputs/current/"
# Package names for the uuids of package_requests_by_date
const GENERAL_REGISTRY_TOML = "https://raw.githubusercontent.com/JuliaRegistries/General/master/Registry.toml"

# The other rollups of the same family, stored as published (see
# docs/database-migration.md, "Package downloads"). Upstream keeps only a
# window of each; package_requests_by_date only three days.
const ROLLUPS = (
    (table = "dl_resource_types", file = "resource_types_by_date",
     keys = ["date", "resource_type", "status", "client_type"],
     cols = ["request_addrs", "request_count", "cache_misses", "body_bytes_sent", "request_time"]),
    (table = "dl_julia_versions", file = "julia_versions_by_date",
     keys = ["date", "julia_version_prefix", "client_type"],
     cols = ["request_addrs", "request_count", "successes", "cache_misses", "body_bytes_sent", "request_time"]),
    (table = "dl_julia_systems", file = "julia_systems_by_date",
     keys = ["date", "julia_system", "client_type"],
     cols = ["request_addrs", "request_count", "successes", "cache_misses", "body_bytes_sent", "request_time"]),
    (table = "dl_client_types", file = "client_types_by_date",
     keys = ["date", "client_type"],
     cols = ["request_addrs", "request_count", "successes", "cache_misses", "body_bytes_sent", "request_time"]),
)
# CSV column names that differ from the table's
const COLUMN_RENAMES = Dict("julia_version_prefix" => "julia_version", "request_time" => "request_time_s")

function is_stable_julia_tag(tag::AbstractString)
    # Keep only final stable release tags like v1.12.6 (exclude rc/alpha/beta).
    return occursin(r"^v\d+\.\d+\.\d+$", tag)
end

function parse_github_datetime(raw::AbstractString)
    s = strip(raw)
    isempty(s) && return nothing
    # GitHub uses UTC timestamps like 2026-06-01T12:34:56Z.
    s = endswith(s, "Z") ? s[1:end-1] : s
    try
        return DateTime(s)
    catch
        return nothing
    end
end


# GET with retries on connection errors, 429 and 5xx, honouring Retry-After
# when the server sends one. HTTP.jl's own retry layer never sees a status
# code once status_exception is off, so this loop covers those.
function http_get_retry(url, headers=Pair{String,String}[]; attempts=4, kwargs...)
    local resp
    for attempt in 1:attempts
        resp = try
            HTTP.get(url, headers; status_exception=false, retry=false, kwargs...)
        catch e
            attempt == attempts && rethrow()
            @warn "Request failed, retrying" url attempt error=e
            sleep(2.0^attempt)
            continue
        end
        (resp.status == 429 || resp.status >= 500) || return resp
        attempt == attempts && return resp
        wait = something(tryparse(Int, HTTP.header(resp, "Retry-After")), 2^attempt)
        @warn "Retrying after HTTP $(resp.status)" url wait attempt
        sleep(wait)
    end
    return resp
end

# The releases API allows 60 anonymous requests an hour per address, shared
# by every hosted runner; the workflow passes its token
function github_headers()
    headers = ["User-Agent" => "julia-ci-timing-fetcher"]
    token = get(ENV, "GITHUB_TOKEN", "")
    isempty(token) || push!(headers, "Authorization" => "Bearer $token")
    return headers
end

function fetch_recent_stable_julia_tags(; years::Int=2)
    cutoff = now(Dates.UTC) - Dates.Year(years)
    tags = Vector{Dict{String,Any}}()
    page = 1

    while true
        url = JULIA_RELEASES_API * "&page=$(page)"
        resp = http_get_retry(url, github_headers(); connect_timeout=30, read_idle_timeout=120)
        resp.status == 200 || error("Failed to fetch Julia releases: HTTP $(resp.status)")
        releases = JSON3.read(resp.body)
        isempty(releases) && break

        for release in releases
            draft = get(release, :draft, false)
            prerelease = get(release, :prerelease, false)
            draft && continue
            prerelease && continue

            tag = String(get(release, :tag_name, ""))
            is_stable_julia_tag(tag) || continue

            published_raw = String(get(release, :published_at, ""))
            isempty(published_raw) && continue
            published_dt = parse_github_datetime(published_raw)
            published_dt === nothing && continue
            published_utc = DateTime(published_dt)
            published_utc < cutoff && continue

            push!(tags, Dict(
                "tag" => tag,
                "date" => Dates.format(Date(published_utc), dateformat"yyyy-mm-dd"),
                "published_at" => Dates.format(published_utc, dateformat"yyyy-mm-ddTHH:MM:SS"),
                "url" => String(get(release, :html_url, "")),
            ))
        end

        # Releases are returned newest-first. Once we've gone past cutoff and
        # there are no matching entries on this page, we can stop.
        oldest_on_page = let last_release = releases[end]
            raw = String(get(last_release, :published_at, ""))
            parse_github_datetime(raw)
        end
        if oldest_on_page !== nothing && oldest_on_page < cutoff
            break
        end

        page += 1
    end

    sort!(tags; by = x -> x["date"])
    return tags
end

function is_prerelease_julia_tag(tag::AbstractString)
    s = lowercase(tag)
    return occursin(r"^v\d+\.\d+\.\d+-(alpha|beta|rc)", s)
end

function fetch_recent_prerelease_julia_tags(; years::Int=2)
    cutoff = now(Dates.UTC) - Dates.Year(years)
    tags = Vector{Dict{String,Any}}()
    page = 1

    while true
        url = JULIA_RELEASES_API * "&page=$(page)"
        resp = http_get_retry(url, github_headers(); connect_timeout=30, read_idle_timeout=120)
        resp.status == 200 || error("Failed to fetch Julia releases: HTTP $(resp.status)")
        releases = JSON3.read(resp.body)
        isempty(releases) && break

        for release in releases
            draft = get(release, :draft, false)
            draft && continue

            tag = String(get(release, :tag_name, ""))
            is_prerelease_julia_tag(tag) || continue

            published_raw = String(get(release, :published_at, ""))
            isempty(published_raw) && continue
            published_dt = parse_github_datetime(published_raw)
            published_dt === nothing && continue
            published_utc = DateTime(published_dt)
            published_utc < cutoff && continue

            push!(tags, Dict(
                "tag" => tag,
                "date" => Dates.format(Date(published_utc), dateformat"yyyy-mm-dd"),
                "published_at" => Dates.format(published_utc, dateformat"yyyy-mm-ddTHH:MM:SS"),
                "url" => String(get(release, :html_url, "")),
            ))
        end

        oldest_on_page = let last_release = releases[end]
            raw = String(get(last_release, :published_at, ""))
            parse_github_datetime(raw)
        end
        if oldest_on_page !== nothing && oldest_on_page < cutoff
            break
        end

        page += 1
    end

    sort!(tags; by = x -> x["date"])
    return tags
end

function parse_csv_line(line::AbstractString)
    out = String[]
    io = IOBuffer()
    in_quotes = false
    i = firstindex(line)
    last = lastindex(line)

    while i <= last
        c = line[i]
        if in_quotes
            if c == '"'
                ni = nextind(line, i)
                if ni <= last && line[ni] == '"'
                    write(io, '"')
                    i = nextind(line, ni)
                else
                    in_quotes = false
                    i = ni
                end
            else
                write(io, c)
                i = nextind(line, i)
            end
        else
            if c == ','
                push!(out, String(take!(io)))
                i = nextind(line, i)
            elseif c == '"'
                in_quotes = true
                i = nextind(line, i)
            else
                write(io, c)
                i = nextind(line, i)
            end
        end
    end

    push!(out, String(take!(io)))
    return out
end

function classify_julia_version_channel(version_prefix::AbstractString)
    s = lowercase(strip(version_prefix))
    if occursin("-dev", s)
        return "exclude"
    end
    if occursin(r"-alpha", s)
        return "alpha"
    elseif occursin(r"-beta", s)
        return "beta"
    elseif occursin(r"-rc", s)
        return "rc"
    elseif occursin(r"^\d+\.\d+\.\d+$", s)
        return "stable"
    else
        # Keep unknown prerelease-like variants visible but separate.
        return "other"
    end
end


function fetch_csv_lines(url)
    resp = HTTP.get(url; retry=true, retries=3, connect_timeout=30, read_idle_timeout=120)
    resp.status == 200 || error("Failed to fetch $url: HTTP $(resp.status)")
    lines = split(String(transcode(GzipDecompressor, resp.body)), '\n'; keepempty=false)
    length(lines) >= 2 || error("$url appears empty")
    return lines
end

numeric(x) = (v = tryparse(Int, x); v !== nothing ? v : (f = tryparse(Float64, x); f === nothing ? missing : f))

# Upsert the rows of one rollup CSV into its table; columns are matched by
# header name so a reordered upstream CSV still lands correctly.
function store_rollup!(db, spec, lines)
    header = parse_csv_line(strip(lines[1]))
    idx = Dict(h => i for (i, h) in enumerate(header))
    for c in vcat(spec.keys, spec.cols)
        haskey(idx, c) || error("$(spec.file): column $c missing from $header")
    end
    column(c) = get(COLUMN_RENAMES, c, c)
    stmt = upsert_stmt(db, spec.table, column.(spec.keys), column.(spec.cols); seq=false)
    n = 0
    for line in @view lines[2:end]
        row = parse_csv_line(strip(line))
        length(row) >= length(header) || continue
        keyvals = Any[c == "status" ? numeric(row[idx[c]]) : row[idx[c]] for c in spec.keys]
        any(v -> v === missing, keyvals) && continue
        upsert!(stmt, (keyvals..., (numeric(row[idx[c]]) for c in spec.cols)...))
        n += 1
    end
    return n
end

# The [packages] table of Registry.toml: one `uuid = { name = "...", path = "..." }` per line
function fetch_registry_packages()
    resp = HTTP.get(GENERAL_REGISTRY_TOML; retry=true, retries=3, connect_timeout=30, read_idle_timeout=120)
    resp.status == 200 || error("Failed to fetch $GENERAL_REGISTRY_TOML: HTTP $(resp.status)")
    packages = NamedTuple[]
    for m in eachmatch(r"^([0-9a-f-]{36})\s*=\s*\{\s*name\s*=\s*\"([^\"]+)\"(?:\s*,\s*path\s*=\s*\"([^\"]*)\")?"m, String(resp.body))
        push!(packages, (uuid = m.captures[1], name = m.captures[2], path = m.captures[3] === nothing ? missing : m.captures[3]))
    end
    length(packages) > 1000 || error("Registry.toml parsed to only $(length(packages)) packages")
    return packages
end

function store_registry_packages!(db, packages)
    stmt = upsert_stmt(db, "registry_packages", ["uuid"], ["name", "path"]; seq=false)
    foreach(p -> upsert!(stmt, (p.uuid, p.name, p.path)), packages)
    return length(packages)
end

# package_requests_by_date: successful requests only, the package as an id
function store_package_requests!(db, lines)
    header = parse_csv_line(strip(lines[1]))
    idx = Dict(h => i for (i, h) in enumerate(header))
    stmt = upsert_stmt(db, "dl_packages", ["date", "package_id", "status", "client_type"],
                       ["request_addrs", "request_count", "cache_misses", "body_bytes_sent"]; seq=false)
    ids = Dict{Tuple,Int}()
    n = 0
    for line in @view lines[2:end]
        row = parse_csv_line(strip(line))
        length(row) >= length(header) || continue
        status = tryparse(Int, row[idx["status"]])
        (status === nothing || !(200 <= status < 400)) && continue
        pid = getid!(ids, db, "dl_package_uuids", ("uuid",), (row[idx["package_uuid"]],))
        upsert!(stmt, (row[idx["date"]], pid, status, row[idx["client_type"]],
                       (numeric(row[idx[c]]) for c in ("request_addrs", "request_count", "cache_misses", "body_bytes_sent"))...))
        n += 1
    end
    return n
end

function main(args=ARGS)
    db = open_db(Store.db_path(args); create=false)

    @info "Fetching package download rollup" url=SOURCE_URL
    lines = fetch_csv_lines(SOURCE_URL)

    totals = Dict{String,Dict{String,Int}}()

    # resource_types_by_date key columns:
    # resource_type,status,client_type,date,...,request_count,...
    for line in @view lines[2:end]
        row = parse_csv_line(strip(line))
        length(row) >= 6 || continue

        resource_type = row[1]
        status = try
            parse(Int, row[2])
        catch
            continue
        end
        client_type = row[3]
        date = row[4]
        request_count = try
            parse(Int, row[6])
        catch
            0
        end

        resource_type == "package" || continue
        # Treat 2xx/3xx as successful package retrieval requests.
        (200 <= status < 400) || continue

        bucket = get!(totals, date) do
            Dict("all" => 0, "user" => 0, "ci" => 0)
        end
        bucket["all"] += request_count
        if client_type == "user"
            bucket["user"] += request_count
        elseif client_type == "ci"
            bucket["ci"] += request_count
        end
    end

    @info "Fetching Julia version rollup for minor-version mix" url=JULIA_VERSIONS_URL
    version_lines = fetch_csv_lines(JULIA_VERSIONS_URL)

    # date => Dict(
    #   "totals" => Dict("all" => Int, "user" => Int, "ci" => Int),
    #   "minors" => Dict(minor => Dict("all" => Int, "user" => Int, "ci" => Int))
    # )
    version_mix = Dict{String,Dict{String,Any}}()

    # date => Dict(
    #   "totals" => Dict("all" => Int, "user" => Int, "ci" => Int),
    #   "channels" => Dict(channel => Dict("all" => Int, "user" => Int, "ci" => Int))
    # )
    version_stage_mix = Dict{String,Dict{String,Any}}()

    for line in @view version_lines[2:end]
        row = parse_csv_line(strip(line))
        length(row) >= 6 || continue

        version_prefix = row[1]
        client_type = row[2]
        date = row[3]
        successes = try
            parse(Int, row[6])
        catch
            0
        end
        successes == 0 && continue

        m = match(r"^(\d+)\.(\d+)\.", version_prefix)
        m === nothing && continue
        minor = string(m.captures[1], ".", m.captures[2])
        channel = classify_julia_version_channel(version_prefix)
        channel == "exclude" && continue

        bucket = get!(version_mix, date) do
            Dict{String,Any}(
                "totals" => Dict("all" => 0, "user" => 0, "ci" => 0),
                "minors" => Dict{String,Any}(),
            )
        end

        totals_dict = bucket["totals"]::Dict{String,Int}
        totals_dict["all"] += successes
        if client_type == "user"
            totals_dict["user"] += successes
        elseif client_type == "ci"
            totals_dict["ci"] += successes
        end

        minors_dict = bucket["minors"]::Dict{String,Any}
        minor_bucket = get!(minors_dict, minor) do
            Dict("all" => 0, "user" => 0, "ci" => 0)
        end
        minor_bucket["all"] += successes
        if client_type == "user"
            minor_bucket["user"] += successes
        elseif client_type == "ci"
            minor_bucket["ci"] += successes
        end

        stage_bucket = get!(version_stage_mix, date) do
            Dict{String,Any}(
                "totals" => Dict("all" => 0, "user" => 0, "ci" => 0),
                "channels" => Dict{String,Any}(),
            )
        end

        stage_totals = stage_bucket["totals"]::Dict{String,Int}
        stage_totals["all"] += successes
        if client_type == "user"
            stage_totals["user"] += successes
        elseif client_type == "ci"
            stage_totals["ci"] += successes
        end

        channels_dict = stage_bucket["channels"]::Dict{String,Any}
        channel_bucket = get!(channels_dict, channel) do
            Dict("all" => 0, "user" => 0, "ci" => 0)
        end
        channel_bucket["all"] += successes
        if client_type == "user"
            channel_bucket["user"] += successes
        elseif client_type == "ci"
            channel_bucket["ci"] += successes
        end
    end

    sorted_dates = sort!(collect(keys(totals)))
    series = Any[
        Dict(
            "date" => d,
            "all" => totals[d]["all"],
            "user" => totals[d]["user"],
            "ci" => totals[d]["ci"],
        ) for d in sorted_dates
    ]

    mix_dates = sort!(collect(keys(version_mix)))
    version_mix_series = Any[
        Dict(
            "date" => d,
            "totals" => version_mix[d]["totals"],
            "minors" => version_mix[d]["minors"],
        ) for d in mix_dates
    ]

    stage_mix_dates = sort!(collect(keys(version_stage_mix)))
    version_stage_mix_series = Any[
        Dict(
            "date" => d,
            "totals" => version_stage_mix[d]["totals"],
            "channels" => version_stage_mix[d]["channels"],
        ) for d in stage_mix_dates
    ]

    @info "Built package downloads series" points=length(series)

    @info "Fetching recent stable Julia tags" years=2
    julia_tags = fetch_recent_stable_julia_tags(; years=2)
    @info "Fetching recent prerelease Julia tags" years=2
    julia_prerelease_tags = fetch_recent_prerelease_julia_tags(; years=2)

    rollup_lines = Dict{String,Any}("resource_types_by_date" => lines, "julia_versions_by_date" => version_lines)
    for name in ("julia_systems_by_date", "client_types_by_date", "package_requests_by_date")
        @info "Fetching rollup" name
        rollup_lines[name] = fetch_csv_lines(PUBLIC_OUTPUTS * name * ".csv.gz")
    end
    @info "Fetching the General registry's package names"
    registry = fetch_registry_packages()

    source_run(db, "packages") do
        transaction(db) do
            n = 0
            for spec in ROLLUPS
                n += store_rollup!(db, spec, rollup_lines[spec.file])
            end
            n += store_package_requests!(db, rollup_lines["package_requests_by_date"])
            n += store_registry_packages!(db, registry)
            @info "Stored rollup rows" rows=n
            seq = next_seq!(db)
            sstmt = upsert_stmt(db, "dl_series", ["date"], ["total_requests", "user_requests", "ci_requests"])
            for e in series
                upsert!(sstmt, (e["date"], e["all"], e["user"], e["ci"], seq))
            end
            mstmt = upsert_stmt(db, "dl_mix", ["date", "kind", "key"], ["total_requests", "user_requests", "ci_requests"]; seq=false)
            for (kind, member, entries) in (("version", "minors", version_mix_series), ("stage", "channels", version_stage_mix_series))
                for e in entries
                    t = e["totals"]
                    upsert!(mstmt, (e["date"], kind, "*", t["all"], t["user"], t["ci"]))
                    for (key, c) in e[member]
                        upsert!(mstmt, (e["date"], kind, key, c["all"], c["user"], c["ci"]))
                    end
                end
            end
            tstmt = upsert_stmt(db, "julia_tags", ["tag"], ["date", "published_at", "url", "prerelease"]; seq=false)
            for (tags, pre) in ((julia_tags, 0), (julia_prerelease_tags, 1))
                for t in tags
                    upsert!(tstmt, (t["tag"], t["date"], t["published_at"], t["url"], pre))
                end
            end
            n + length(series)
        end
    end
    close(db)
    return 0
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
