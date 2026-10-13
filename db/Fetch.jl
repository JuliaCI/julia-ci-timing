# What the fetch_*.jl scripts share for talking to upstream services.

using HTTP

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
