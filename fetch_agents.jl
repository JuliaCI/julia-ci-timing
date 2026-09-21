#!/usr/bin/env julia
# Snapshot the Buildkite agents of the julialang organization.
#
# The Workers tab infers agent presence from finished master jobs, which says nothing
# about agents that only run PR jobs and lags a dropped agent by up to a day. This
# script asks the agents API directly on every run of the update workflow and keeps
# the answer in the database (db/): one `agent_snapshots` row per run with the
# connected agent names in `agent_snapshot_members`, and the latest details of
# every agent in `agents`. db/export.jl renders data/agents/ from them:
#
#   history-YYYY-MM.ndjson  one line per run: the time and the agent names connected
#                           then.
#   latest.json             the latest details of every agent seen in the retained
#                           window (host, queue, state, current job), with sorted
#                           keys so the rewrite each run diffs cleanly.
#
# The site draws connected agents per queue over time from the history and flags
# agents that were connected recently but are not now. The build, test, launch and
# default queues are the exception: their hosts start one agent per job (see
# JuliaCI/sandboxed-buildkite-agent), so a listing only shows the slots mid-job
# and the site judges those per host, by the last snapshot any slot appeared in.
#
# Needs a token with the read_agents scope. Without it the script warns and exits
# cleanly so a missing scope does not fail the workflow and block deploys.

using HTTP
using JSON3
using Dates
using DataStructures: OrderedDict

include(joinpath(@__DIR__, "db", "Store.jl"))
using .Store
using SQLite, DBInterface

const BUILDKITE_ORG = "julialang"
const API_BASE = "https://api.buildkite.com/v2"
const RETAIN_MONTHS = 12   # applied by the export, not by deletion
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

fold_key(name) = replace(name, r"\.\d+$" => "")

const AGENT_COLS = ["fold_key", "agent_id", "hostname", "queue", "os", "arch", "version", "meta_data", "state",
                    "connected_at", "first_seen", "last_seen", "job_json"]

# Fold one API listing into the database. Only agents the API reports as
# connected count as present in the snapshot; a lost or stopping agent keeps
# its record so the state shows in the table. Nothing is deleted: the
# retention window is applied when the files are rendered.
function record_snapshot!(db, agents, now_time::DateTime)
    snapshot_time = Dates.format(now_time, DATEFMT)
    seq = next_seq!(db)
    first_seen = Dict{String,String}()
    for r in query(db, "SELECT name, first_seen FROM agents")
        first_seen[String(r.name)] = r.first_seen === missing ? "" : String(r.first_seen)
    end
    stmt = upsert_stmt(db, "agents", ["name"], AGENT_COLS)
    connected = String[]
    for agent in agents
        name = str(get(agent, :name, nothing))
        isempty(name) && continue
        rec = agent_record(agent, snapshot_time, get(first_seen, name, snapshot_time))
        rec["state"] == "connected" && push!(connected, name)
        tags = something(get(agent, :meta_data, nothing), [])
        upsert!(stmt, (name, fold_key(name), str(get(agent, :id, nothing)), rec["hostname"], rec["queue"], rec["os"], rec["arch"],
                       rec["version"], JSON3.write(String.(tags)), rec["state"], rec["connected_at"], rec["first_seen"],
                       rec["last_seen"], rec["job"] === nothing ? missing : JSON3.write(rec["job"]), seq))
    end
    sort!(connected)
    # A stale job on an agent that has since gone away must not look current
    DBInterface.execute(db, "UPDATE agents SET job_json = NULL, state = CASE state WHEN 'connected' THEN 'disconnected' ELSE state END, " *
                            "change_seq = ? WHERE name NOT IN (SELECT value FROM json_each(?)) AND (job_json IS NOT NULL OR state = 'connected')",
                        (seq, JSON3.write(connected)))
    DBInterface.execute(db, "INSERT OR IGNORE INTO agent_snapshots (time) VALUES (?)", (snapshot_time,))
    mstmt = DBInterface.prepare(db, "INSERT OR IGNORE INTO agent_snapshot_members (time, agent_name) VALUES (?, ?)")
    for name in connected
        DBInterface.execute(mstmt, (snapshot_time, name))
    end
    return connected
end

function main(args=ARGS)
    agents = fetch_agents()
    agents === nothing && return 0
    db = open_db(Store.db_path(args); create=false)
    connected = source_run(db, "agents") do
        transaction(db) do
            record_snapshot!(db, agents, now(UTC))
        end
    end
    @info "Agents listed" total=length(agents) connected=length(connected)
    close(db)
    return 0
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
