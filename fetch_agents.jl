#!/usr/bin/env julia
# Snapshot the Buildkite agents of the julialang organization.
#
# The Workers tab infers agent presence from finished master jobs, which says nothing
# about agents that only run PR jobs and lags a dropped agent by up to a day. This
# script asks the agents API directly on every ingest run and keeps
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
# It also keeps the jobs of the julia-pr and julia-ci builds in `pool_jobs`: when each
# became runnable, started and finished, and the agent pool (queue, os, arch) it asked
# for, so the Workers tab can draw how many jobs wait for each pool. A run fetches the
# builds still going and those finished since the last successful run; the first run
# backfills POOL_BACKFILL_DAYS.
#
# The site draws connected agents per queue over time from the history and flags
# agents that were connected recently but are not now. The build, test, launch and
# default queues are the exception: their hosts start one agent per job (see
# JuliaCI/sandboxed-buildkite-agent), so a listing only shows the slots mid-job
# and the site judges those per host, by the last snapshot any slot appeared in.
#
# Needs a token with the read_agents and read_builds scopes. Without it the run fails and says so in
# source_runs, where /healthz and the daily check pick it up.

using HTTP
using JSON3
using Dates
using DataStructures: OrderedDict

# The package has the store precompiled
using CITiming.Store
include(joinpath(@__DIR__, "db", "Fetch.jl"))
using SQLite, DBInterface

const RETAIN_MONTHS = 12   # applied by the export, not by deletion

# Every agent the API lists, across pages
function fetch_agents()
    agents = Any[]
    buildkite_pages("organizations/$BUILDKITE_ORG/agents"; max_pages=50) do batch, _
        append!(agents, batch)
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
    snapshot_time = Store.iso(now_time)
    seq = next_seq!(db)
    first_seen = Dict{String,String}()
    for r in query(db, "SELECT name, first_seen FROM agents")
        first_seen[String(r.name)] = r.first_seen === missing ? "" : String(r.first_seen)
    end
    stmt = upsert_stmt(db, "agents", ["name"], AGENT_COLS)
    connected = String[]
    pipelines = Dict{String,String}()
    for agent in agents
        name = str(get(agent, :name, nothing))
        isempty(name) && continue
        rec = agent_record(agent, snapshot_time, get(first_seen, name, snapshot_time))
        if rec["state"] == "connected"
            push!(connected, name)
            pipelines[name] = rec["job"] === nothing ? "" : rec["job"]["pipeline"]
        end
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
    mstmt = DBInterface.prepare(db, "INSERT OR IGNORE INTO agent_snapshot_members (time, agent_name, pipeline) VALUES (?, ?, ?)")
    for name in connected
        DBInterface.execute(mstmt, (snapshot_time, name, pipelines[name]))
    end
    return connected
end

# --- pool jobs ------------------------------------------------------------------

const POOL_PIPELINES = ["julia-pr", "julia-ci"]
const ACTIVE_BUILD_STATES = ["scheduled", "running", "failing", "canceling"]
const POOL_BACKFILL_DAYS = 30
const POOL_JOB_RETAIN_DAYS = 60
# Builds that finish while a run is listing them are caught by the next run
const POOL_OVERLAP = Hour(2)

# Every build of `pipeline` matching `params` (pairs, repeated keys allowed), across pages
function fetch_builds(pipeline, params)
    builds = Any[]
    buildkite_pages("organizations/$BUILDKITE_ORG/pipelines/$pipeline/builds", params; max_pages=200) do batch, _
        append!(builds, batch)
    end
    return builds
end

at(x) = x === nothing ? missing : Store.iso(Store.parse_upstream(String(x)))

function rule_value(rules, key)
    prefix = key * "="
    for r in rules
        s = String(r)
        startswith(s, prefix) && return s[length(prefix)+1:end]
    end
    return ""
end

const POOL_JOB_COLS = ["pipeline", "build", "name", "queue", "os", "arch", "state", "runnable_at", "started_at", "finished_at"]
const OPEN_JOB_STATES = ["scheduled", "reserved", "assigned", "accepted", "limited", "limiting", "waiting", "blocked",
                         "running", "canceling", "timing_out"]
const OPEN_JOB_SQL = "state IN (" * join(("'$s'" for s in OPEN_JOB_STATES), ", ") * ")"

# Upsert the runnable script jobs of `builds`; returns how many were written
function record_pool_jobs!(db, pipeline, builds)
    stmt = upsert_stmt(db, "pool_jobs", ["job_uuid"], POOL_JOB_COLS)
    # A finished build can leave a job open, or drop it from its listing, and
    # such a job would otherwise wait or run forever in the backlog
    close_stmt = DBInterface.prepare(db, "UPDATE pool_jobs SET state = 'lost', finished_at = ?, change_seq = ? " *
                                         "WHERE pipeline = ? AND build = ? AND finished_at IS NULL AND $OPEN_JOB_SQL")
    seq = next_seq!(db)
    n = 0
    for build in builds
        for job in something(get(build, :jobs, nothing), [])
            get(job, :type, nothing) == "script" || continue
            runnable = get(job, :runnable_at, nothing)
            runnable === nothing && continue
            rules = something(get(job, :agent_query_rules, nothing), [])
            upsert!(stmt, (String(job.id), pipeline, Int(build.number), str(get(job, :name, nothing)),
                           rule_value(rules, "queue"), rule_value(rules, "os"), rule_value(rules, "arch"),
                           str(get(job, :state, nothing)), at(runnable), at(get(job, :started_at, nothing)),
                           at(get(job, :finished_at, nothing)), seq))
            n += 1
        end
        finished = get(build, :finished_at, nothing)
        finished === nothing || DBInterface.execute(close_stmt, (at(finished), seq, pipeline, Int(build.number)))
    end
    return n
end

# Builds with open jobs that neither listing returned: they finished before
# the window, so each is fetched alone to close its jobs
function stale_builds(db, pipeline, listed)
    seen = Set(Int(b.number) for b in listed)
    builds = Any[]
    for r in query(db, "SELECT DISTINCT build FROM pool_jobs WHERE pipeline = ? AND finished_at IS NULL AND $OPEN_JOB_SQL", (pipeline,))
        Int(r.build) in seen && continue
        b = buildkite_get("organizations/$BUILDKITE_ORG/pipelines/$pipeline/builds/$(r.build)")
        b === nothing || push!(builds, b)
    end
    return builds
end

# Start of the window of finished builds to fetch: shortly before the last
# successful run, or the backfill window when there are no jobs yet
function pool_window_start(db, now_time)
    isempty(query(db, "SELECT 1 FROM pool_jobs LIMIT 1")) && return ("created_from", now_time - Day(POOL_BACKFILL_DAYS))
    r = query(db, "SELECT started_at FROM source_runs WHERE source = 'agents' AND ok = 1 ORDER BY id DESC LIMIT 1")
    last_ok = isempty(r) ? now_time - Day(1) : Store.parse_upstream(String(r[1].started_at))
    return ("finished_from", max(last_ok - POOL_OVERLAP, now_time - Day(POOL_BACKFILL_DAYS)))
end

function update_pool_jobs!(db, now_time::DateTime)
    key, from = pool_window_start(db, now_time)
    fetched = Dict{String,Vector{Any}}()
    for pipeline in POOL_PIPELINES
        active = fetch_builds(pipeline, ["state[]" => s for s in ACTIVE_BUILD_STATES])
        recent = fetch_builds(pipeline, [key => Store.iso(from)])
        fetched[pipeline] = vcat(active, recent)
        append!(fetched[pipeline], stale_builds(db, pipeline, fetched[pipeline]))
    end
    return transaction(db) do
        n = sum(record_pool_jobs!(db, p, b) for (p, b) in fetched)
        cutoff = Store.iso(now_time - Day(POOL_JOB_RETAIN_DAYS))
        DBInterface.execute(db, "DELETE FROM pool_jobs WHERE runnable_at < ?", (cutoff,))
        @info "Pool jobs recorded" window=key from builds=sum(length, values(fetched)) jobs=n
        n
    end
end

function main(args=ARGS)
    db = open_db(Store.db_path(args); create=false)
    source_run(db, "agents") do
        now_time = now(UTC)
        agents = fetch_agents()
        connected = transaction(db) do
            record_snapshot!(db, agents, now_time)
        end
        @info "Agents listed" total=length(agents) connected=length(connected)
        # After the snapshot is stored, so a builds failure does not lose it
        update_pool_jobs!(db, now_time)
    end
    close(db)
    return 0
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
