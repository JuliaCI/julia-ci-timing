# What the fetch_*.jl scripts share for talking to upstream services.

using HTTP, JSON3

const MAX_RETRY_WAIT_S = 120

# How long a 429 or 5xx asks to be left alone: Retry-After, or Buildkite's
# RateLimit-Reset (seconds until its per-minute budget refills), capped so a
# bad header cannot stall the run
function retry_wait(resp, attempt)
    for h in ("Retry-After", "RateLimit-Reset")
        s = tryparse(Int, HTTP.header(resp, h))
        s === nothing || return clamp(s + 1, 1, MAX_RETRY_WAIT_S)
    end
    return 2^attempt
end

# GET with retries on connection errors, 429 and 5xx. HTTP.jl's own retry
# layer never sees a status code once status_exception is off, so this loop
# covers those.
function http_get_retry(url, headers=Pair{String,String}[]; attempts=4, read_idle_timeout=120, connect_timeout=30, kwargs...)
    local resp
    for attempt in 1:attempts
        resp = try
            HTTP.get(url, headers; status_exception=false, retry=false, read_idle_timeout, connect_timeout, kwargs...)
        catch e
            attempt == attempts && rethrow()
            @warn "Request failed, retrying" url attempt error=e
            sleep(2.0^attempt)
            continue
        end
        (resp.status == 429 || resp.status >= 500) || return resp
        attempt == attempts && return resp
        wait = retry_wait(resp, attempt)
        @warn "Retrying after HTTP $(resp.status)" url wait attempt
        sleep(wait)
    end
    return resp
end

# --- Buildkite ------------------------------------------------------------

const BUILDKITE_API = "https://api.buildkite.com/v2"
const BUILDKITE_ORG = "julialang"

function buildkite_token()
    # An empty variable (the host exports one when the parameter is unset)
    # counts as unset
    token = strip(get(ENV, "BUILDKITE_API_TOKEN", ""))
    if isempty(token)
        token_file = joinpath(homedir(), ".buildkite_token")
        isfile(token_file) && (token = strip(read(token_file, String)))
    end
    isempty(token) && error("Set BUILDKITE_API_TOKEN env var or create ~/.buildkite_token")
    return token
end

# Pairs rather than a Dict, so a key can repeat (`state[]`)
query_string(params) = join(["$(HTTP.escapeuri(string(k)))=$(HTTP.escapeuri(string(v)))" for (k, v) in params], "&")

function buildkite_url(endpoint, params=())
    url = "$BUILDKITE_API/$endpoint"
    return isempty(params) ? url : url * "?" * query_string(params)
end

# The parsed answer, or nothing (with a warning) when the request failed
function buildkite_get(endpoint; token=buildkite_token(), params=())
    url = buildkite_url(endpoint, params)
    resp = http_get_retry(url, ["Authorization" => "Bearer $token"])
    if resp.status != 200
        @warn "API request failed" url resp.status String(resp.body)
        return nothing
    end
    return JSON3.read(resp.body)
end

# The `rel="next"` URL of a Link header, or nothing on the last page
function next_link(link::AbstractString)
    for m in eachmatch(r"<([^>]*)>\s*;\s*rel=\"?next\"?", link)
        return String(m.captures[1])
    end
    return nothing
end

"""
    buildkite_pages(f, endpoint, params=(); max_pages, per_page=100, token=buildkite_token())

Call `f(batch, page)` on each non-empty page of a Buildkite listing, following the
`Link` header's next page, until the last page, `f` returns `:stop`, or `max_pages`
pages have been read (which warns, since the listing is then cut short). A failed
request throws, so a partial listing is never taken for a whole one.
"""
function buildkite_pages(f, endpoint, params=(); max_pages::Int, per_page=100, token=buildkite_token())
    url = buildkite_url(endpoint, [collect(params); "per_page" => per_page])
    for page in 1:max_pages
        resp = http_get_retry(url, ["Authorization" => "Bearer $token"])
        if resp.status in (401, 403)
            error("The token cannot read $endpoint (HTTP $(resp.status); check its scopes)")
        end
        resp.status == 200 || error("Listing $endpoint failed on page $page with HTTP $(resp.status): $(String(resp.body))")
        batch = JSON3.read(resp.body)
        isempty(batch) && return
        f(batch, page) === :stop && return
        next = next_link(HTTP.header(resp, "Link"))
        next === nothing && return
        page == max_pages && @warn "Stopped at the page cap; the rest of the listing is left out" endpoint max_pages
        url = next
    end
end

"""
    download_artifact(url; token=buildkite_token(), io=nothing)

Download a Buildkite artifact. The endpoint answers with a redirect to a signed storage
URL, followed by hand so the API token is not sent along to the storage host. Without
`io`, returns the body, or nothing (with a warning) when it failed. With `io`, streams
the file into it and throws when it failed.
"""
function download_artifact(url; token=buildkite_token(), io=nothing)
    resp = http_get_retry(url, ["Authorization" => "Bearer $token"]; redirect=false)
    redirected = resp.status in (301, 302, 303, 307, 308)
    if io !== nothing
        redirected || error("artifact download failed: HTTP $(resp.status)")
        return HTTP.get(HTTP.header(resp, "Location"); response_stream=io, retry=true, read_idle_timeout=120)
    end
    redirected && (resp = http_get_retry(HTTP.header(resp, "Location")))
    if resp.status != 200
        @warn "Artifact download failed" url resp.status
        return nothing
    end
    return resp.body
end

# --- GitHub ---------------------------------------------------------------

const GITHUB_REPO = "https://api.github.com/repos/JuliaLang/julia"

# The host passes no token: anonymously, GitHub allows an address 60 requests an hour,
# shared by every fetcher
function github_headers()
    headers = ["User-Agent" => "julia-ci-timing-fetcher", "Accept" => "application/vnd.github+json"]
    token = get(ENV, "GITHUB_TOKEN", "")
    isempty(token) || push!(headers, "Authorization" => "Bearer $token")
    return headers
end

# Every open pull request of julia, by number. Throws rather than return part of the
# list, which would drop the rows of the pull requests left out.
function github_open_pulls()
    pulls = Dict{Int,Any}()
    for page in 1:50
        resp = http_get_retry("$GITHUB_REPO/pulls?state=open&per_page=100&page=$page", github_headers())
        resp.status == 200 || error("listing open pull requests failed: HTTP $(resp.status)")
        list = JSON3.read(resp.body)
        isempty(list) && return pulls
        for p in list
            pulls[Int(p.number)] = p
        end
    end
    error("more than 5000 open pull requests")
end

# One pull request, or nothing (with a warning) when the request failed
function github_pull(n)
    resp = http_get_retry("$GITHUB_REPO/pulls/$n", github_headers())
    if resp.status != 200
        @warn "Looking up a pull request failed" n resp.status
        return nothing
    end
    return JSON3.read(resp.body)
end

# --- NanosoldierReports ---------------------------------------------------

const REPORTS_REPO = "https://github.com/JuliaCI/NanosoldierReports.git"

# A shallow clone of the reports at `dir`, reset to master. Only `paths` are checked
# out; with none, only the tree is there to list.
function ensure_clone(dir; paths=String[])
    if isdir(joinpath(dir, ".git"))
        @info "Updating existing clone..." dir
        run(`git -C $dir fetch --depth 1 origin`)
        run(`git -C $dir reset --hard origin/master`)
    else
        @info "Cloning NanosoldierReports (sparse)..." dir
        rm(dir; force=true, recursive=true)
        mkpath(dirname(dir))
        run(`git clone --depth 1 --filter=blob:none --sparse $REPORTS_REPO $dir`)
        isempty(paths) || run(`git -C $dir sparse-checkout set $paths`)
    end
    return dir
end

# A report's `YYYY-MM/DD` directory as its date, `YYYY-MM-DD`
function date_path_to_date(path::AbstractString)
    parts = split(path, "/")
    "$(parts[1])-$(lpad(parts[2], 2, '0'))"
end
