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
using CodecZlib: GzipCompressor, GzipDecompressor

const SOURCE_URL =
    "https://julialang-logs.s3.amazonaws.com/public_outputs/current/resource_types_by_date.csv.gz"
const JULIA_VERSIONS_URL =
    "https://julialang-logs.s3.amazonaws.com/public_outputs/current/julia_versions_by_date.csv.gz"
const JULIA_RELEASES_API = "https://api.github.com/repos/JuliaLang/julia/releases?per_page=100"

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

function fetch_recent_stable_julia_tags(; years::Int=2)
    cutoff = now(Dates.UTC) - Dates.Year(years)
    tags = Vector{Dict{String,Any}}()
    page = 1

    while true
        url = JULIA_RELEASES_API * "&page=$(page)"
        resp = HTTP.get(url;
            retry=true,
            retries=3,
            connect_timeout=30,
            readtimeout=120,
            headers=Dict("User-Agent" => "julia-ci-timing-fetcher"),
        )
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

function load_existing(output_dir::AbstractString)
    path = joinpath(output_dir, "packages_downloads_summary.json.gz")
    if !isfile(path)
        return nothing
    end
    try
        return JSON3.read(transcode(GzipDecompressor, read(path)))
    catch e
        @warn "Failed to read existing packages summary, rebuilding" error=e
        return nothing
    end
end

function main()
    output_dir = "data"
    mkpath(output_dir)

    @info "Fetching package download rollup" url=SOURCE_URL
    resp = HTTP.get(SOURCE_URL; retry=true, retries=3, connect_timeout=30, readtimeout=120)
    resp.status == 200 || error("Failed to fetch rollup: HTTP $(resp.status)")

    csv_text = String(transcode(GzipDecompressor, resp.body))
    lines = split(csv_text, '\n'; keepempty=false)
    length(lines) >= 2 || error("Rollup CSV appears empty")

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
    versions_resp = HTTP.get(JULIA_VERSIONS_URL; retry=true, retries=3, connect_timeout=30, readtimeout=120)
    versions_resp.status == 200 || error("Failed to fetch julia_versions_by_date rollup: HTTP $(versions_resp.status)")
    versions_csv = String(transcode(GzipDecompressor, versions_resp.body))
    version_lines = split(versions_csv, '\n'; keepempty=false)
    length(version_lines) >= 2 || error("julia_versions_by_date CSV appears empty")

    # date => Dict(
    #   "totals" => Dict("all" => Int, "user" => Int, "ci" => Int),
    #   "minors" => Dict(minor => Dict("all" => Int, "user" => Int, "ci" => Int))
    # )
    version_mix = Dict{String,Dict{String,Any}}()

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

    existing = load_existing(output_dir)
    if existing !== nothing
        old_len = length(get(existing, :series, Any[]))
        new_len = length(series)
        @info "Built package downloads series" old_points=old_len new_points=new_len
    else
        @info "Built package downloads series" points=length(series)
    end

    @info "Fetching recent stable Julia tags" years=2
    julia_tags = fetch_recent_stable_julia_tags(; years=2)

    payload = Dict(
        "generated_at" => Dates.format(now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SSZ"),
        "source" => SOURCE_URL,
        "julia_versions_source" => JULIA_VERSIONS_URL,
        "julia_tags_source" => "https://api.github.com/repos/JuliaLang/julia/releases",
        "julia_tags_window_years" => 2,
        "julia_tags" => julia_tags,
        "maxDate" => isempty(sorted_dates) ? nothing : sorted_dates[end],
        "series" => series,
        "version_mix" => version_mix_series,
    )

    out_path = joinpath(output_dir, "packages_downloads_summary.json.gz")
    json_bytes = Vector{UInt8}(JSON3.write(payload))
    write(out_path, transcode(GzipCompressor, json_bytes))
    @info "Wrote package downloads summary" path=out_path bytes=filesize(out_path)

    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
