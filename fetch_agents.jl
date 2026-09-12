#!/usr/bin/env julia
# Snapshot the Buildkite agents of the julialang organization.
#
# The Workers tab infers agent presence from finished master jobs, which says nothing
# about agents that only run PR jobs and lags a dropped agent by up to a day. This
# script asks the agents API directly on every run of the update workflow and keeps
# the answer under data/agents/:
#
#   history-YYYY-MM.ndjson  one line per run: the time and the agent names connected
#                           then. Append-only plain text, so each run costs git one
#                           line rather than a fresh binary blob.
#   latest.json             the latest details of every agent seen in the retained
#                           window (host, queue, state, current job), with sorted
#                           keys so the rewrite each run diffs cleanly.
#
# The site draws connected agents per queue over time from the history and flags
# agents that were connected recently but are not now.
#
# Needs a token with the read_agents scope. Without it the script warns and exits
# cleanly so a missing scope does not fail the workflow and block deploys.

using HTTP
using JSON3
using Dates
using DataStructures: OrderedDict

const BUILDKITE_ORG = "julialang"
const API_BASE = "https://api.buildkite.com/v2"
const DATA_DIR = joinpath("data", "agents")
const LATEST = joinpath(DATA_DIR, "latest.json")
const RETAIN_MONTHS = 12
const DATEFMT = dateformat"yyyy-mm-ddTHH:MM:SSZ"

function get_token()
    token = get(ENV, "BUILDKITE_API_TOKEN", nothing)
    if token === nothing
        token_file = joinpath(homedir(), ".buildkite_token")
        isfile(token_file) && (token = strip(read(token_file, String)))
    end
    token === nothing && error("Set BUILDKITE_API_TOKEN env var or create ~/.buildkite_token")
    return token
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

# Every agent the API lists, across pages. Returns nothing when the token cannot
# read agents, so the caller can skip rather than fail.
function fetch_agents(; token=get_token(), per_page=100)
    agents = Any[]
    for page in 1:50
        url = "$API_BASE/organizations/$BUILDKITE_ORG/agents?per_page=$per_page&page=$page"
        resp = http_get_retry(url, ["Authorization" => "Bearer $token"])
        if resp.status in (401, 403)
            @warn "The token cannot list agents (needs the read_agents scope); skipping" resp.status
            return nothing
        end
        if resp.status != 200
            error("Agents request failed with HTTP $(resp.status): $(String(resp.body))")
        end
        batch = JSON3.read(resp.body)
        append!(agents, batch)
        length(batch) < per_page && break
    end
    return agents
end

function meta_value(agent, key)
    prefix = key * "="
    for m in get(agent, :meta_data, ())
        s = String(m)
        startswith(s, prefix) && return s[length(prefix)+1:end]
    end
    return ""
end

str(x) = x === nothing ? "" : String(x)

# The details kept per agent: what the site shows in the live table. Field order
# is fixed so the file diffs cleanly between runs.
function agent_record(agent, snapshot_time::String, first_seen::String)
    job = get(agent, :job, nothing)
    jobrec = if job === nothing
        nothing
    else
        # build_url looks like .../pipelines/julia-pr/builds/2334
        m = match(r"/pipelines/([^/]+)/builds/(\d+)", str(get(job, :build_url, nothing)))
        OrderedDict{String,Any}(
            "name" => str(get(job, :name, nothing)),
            "pipeline" => m === nothing ? "" : m.captures[1],
            "build" => m === nothing ? nothing : parse(Int, m.captures[2]),
            "started_at" => str(get(job, :started_at, nothing)),
        )
    end
    queue = str(get(agent, :queue, nothing))
    isempty(queue) && (queue = meta_value(agent, "queue"))
    return OrderedDict{String,Any}(
        "hostname" => str(get(agent, :hostname, nothing)),
        "queue" => queue,
        "os" => meta_value(agent, "os"),
        "arch" => meta_value(agent, "arch"),
        "version" => str(get(agent, :version, nothing)),
        "state" => str(get(agent, :connection_state, nothing)),
        "connected_at" => str(get(agent, :created_at, nothing)),
        "first_seen" => first_seen,
        "last_seen" => snapshot_time,
        "job" => jobrec,
    )
end

function load_latest()
    isfile(LATEST) || return Dict{String,Any}()
    raw = JSON3.read(read(LATEST, String), Dict{String,Any})
    return get(raw, "agents", Dict{String,Any}())
end

history_file(t::DateTime) = joinpath(DATA_DIR, "history-" * Dates.format(t, dateformat"yyyy-mm") * ".ndjson")

# Fold one API listing into the data files. Only agents the API reports as
# connected count as present in the snapshot; a lost or stopping agent keeps its
# record so the state shows in the table.
function record_snapshot!(agents, now_time::DateTime)
    snapshot_time = Dates.format(now_time, DATEFMT)
    records = load_latest()
    connected = String[]
    for agent in agents
        name = str(get(agent, :name, nothing))
        isempty(name) && continue
        old = get(records, name, nothing)
        first_seen = old === nothing ? snapshot_time : String(get(old, "first_seen", snapshot_time))
        rec = agent_record(agent, snapshot_time, first_seen)
        rec["state"] == "connected" && push!(connected, name)
        records[name] = rec
    end
    sort!(connected)
    # A stale job on an agent that has since gone away must not look current
    for (name, rec) in records
        name in connected && continue
        rec["job"] = nothing
        get(rec, "state", "") == "connected" && (rec["state"] = "disconnected")
    end
    # Drop agents unseen for the retained window
    cutoff = Dates.format(now_time - Month(RETAIN_MONTHS), DATEFMT)
    filter!(((name, rec),) -> String(get(rec, "last_seen", "")) >= cutoff, records)

    mkpath(DATA_DIR)
    open(history_file(now_time), "a") do io
        JSON3.write(io, OrderedDict("time" => snapshot_time, "connected" => connected))
        println(io)
    end
    latest = OrderedDict{String,Any}(
        "generated_at" => snapshot_time,
        "agents" => OrderedDict{String,Any}(name => records[name] for name in sort!(collect(keys(records)))),
    )
    open(LATEST, "w") do io
        JSON3.pretty(io, JSON3.write(latest), JSON3.AlignmentContext(indent=1))
        println(io)
    end
    for f in readdir(DATA_DIR)
        m = match(r"^history-(\d{4}-\d{2})\.ndjson$", f)
        m === nothing && continue
        m.captures[1] < Dates.format(now_time - Month(RETAIN_MONTHS), dateformat"yyyy-mm") && rm(joinpath(DATA_DIR, f))
    end
    return connected
end

function main()
    agents = fetch_agents()
    agents === nothing && return 0
    connected = record_snapshot!(agents, now(UTC))
    @info "Agents listed" total=length(agents) connected=length(connected) file=LATEST
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
