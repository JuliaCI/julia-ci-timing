"""
Render: the shapes the site reads, built from the database.

    include("db/Render.jl"); using .Render
    Render.timing(db; since="2026-08-01T00:00:00Z")

`db/export.jl` writes these to `data/*` (the extracts scripts download);
`db/serve.jl` serves them on demand with a window, so the browser only
loads what it shows. Every function takes an open
`SQLite.DB` and returns a JSON-serializable value in the shape the
fetchers wrote before the database existed (`docs/database-migration.md`).
"""
module Render

using ..Store
using SQLite, DBInterface, JSON3, DataStructures, Dates, Statistics

rows(db, sql, params=()) = query(db, sql, params)

# SQL NULL comes back as `missing`; the files use null (or "" where the
# fetcher wrote strings).
js(x) = x === missing ? nothing : x
jstr(x) = x === missing ? "" : String(x)

"Finish time of the last successful run of a source, or now if it never ran."
function generated_at(db, source)
    r = rows(db, "SELECT finished_at FROM source_runs WHERE source = ? AND ok = 1 ORDER BY id DESC LIMIT 1", (source,))
    return isempty(r) ? Store.iso_now() : String(r[1].finished_at)
end

# Windows arrive as dates or instants; '' means unbounded. A cursor of 0
# means everything, and is left out so the planner can use the window's
# index.
function where_clause(col, since, until; seq_col=nothing, changed_since=0)
    clauses = String[]
    params = Any[]
    isempty(since) || (push!(clauses, "$col >= ?"); push!(params, since))
    isempty(until) || (push!(clauses, "$col < ?"); push!(params, until))
    changed_since > 0 && (push!(clauses, "$seq_col > ?"); push!(params, changed_since))
    return (isempty(clauses) ? "" : " WHERE " * join(clauses, " AND ")), params
end

# --- timing ----------------------------------------------------------------

# Runs per job, newest first. `since`/`until` bound the build's created_at,
# `changed_since` selects every job of the builds touched after that change
# sequence (an incremental refresh: the client replaces those builds' runs,
# so a row the fetcher deleted, a job moved to another retry slot, goes
# away too, and a build-only change is carried); with `stats` each job also carries the all-time
# duration statistics the legacy file had. With a `builds` dictionary the
# runs carry only what is theirs (agent, state, duration) and the build's
# commit, author, message and date go into it once, keyed pipeline#number:
# the API's shape, a third the size of the legacy one where every run
# repeats its build.
function timing_jobs(db; since="", until="", changed_since=0, stats=false, builds=nothing)
    # Legacy order: date descending, then retry ascending. Number descending
    # settles ties within a pipeline the way the fetcher's merge did; ties
    # across pipelines in the same minute were fetch-order accidents.
    where, params = where_clause("b.created_at", since, until)
    if changed_since > 0
        where *= (isempty(where) ? " WHERE " : " AND ") *
                 "j.build_id IN (SELECT build_id FROM jobs WHERE change_seq > ? UNION SELECT id FROM builds WHERE change_seq > ?)"
        push!(params, changed_since, changed_since)
    end
    q = rows(db, "SELECT j.name, j.retry, j.agent_hostname, j.state, j.duration_s, " *
                 "b.pipeline, b.number, b.commit_prefix, b.author, b.message, b.created_at " *
                 "FROM jobs j JOIN builds b ON b.id = j.build_id" * where *
                 " ORDER BY j.name, b.created_at DESC, j.retry ASC, b.number DESC", params)
    jobs = SortedDict{String,Any}()
    # Every job the database knows, so the selector is complete even when
    # none of a job's runs fall in the window. Not for incremental refreshes:
    # those only carry what changed.
    if changed_since == 0
        for r in rows(db, "SELECT DISTINCT name FROM jobs")
            jobs[String(r.name)] = OrderedDict{String,Any}("recent" => Any[])
        end
    end
    current = nothing
    recent = Any[]
    durations = Float64[]
    function flush!()
        current === nothing && return
        job = OrderedDict{String,Any}("recent" => copy(recent))
        if stats
            n = length(durations)
            job["stats"] = SortedDict(
                "count" => n,
                "max_seconds" => round(maximum(durations); digits=1),
                "mean_seconds" => round(mean(durations); digits=1),
                "median_seconds" => round(median(durations); digits=1),
                "min_seconds" => round(minimum(durations); digits=1),
                "std_seconds" => round(n > 1 ? std(durations) : 0.0; digits=1))
        end
        jobs[current] = job
    end
    for r in q
        name = String(r.name)
        if name != current
            flush!()
            current = name
            empty!(recent); empty!(durations)
        end
        if builds === nothing
            push!(recent, (
                agent = String(r.agent_hostname), author = String(r.author), build = Int(r.number),
                commit = String(r.commit_prefix), date = iso_to_legacy_minute(String(r.created_at)),
                duration = Float64(r.duration_s), message = String(r.message), pipeline = String(r.pipeline),
                retry = Int(r.retry), state = String(r.state)))
        else
            key = "$(r.pipeline)#$(r.number)"
            haskey(builds, key) || (builds[key] = (commit = String(r.commit_prefix), author = String(r.author),
                                                    message = String(r.message), date = iso_to_legacy_minute(String(r.created_at))))
            push!(recent, (agent = String(r.agent_hostname), build = Int(r.number), duration = Float64(r.duration_s),
                           pipeline = String(r.pipeline), retry = Int(r.retry), state = String(r.state)))
        end
        push!(durations, Float64(r.duration_s))
    end
    flush!()
    return jobs
end

function coverage(db; changed_since=0)
    out = SortedDict{String,Any}()
    where, params = where_clause("", "", ""; seq_col="change_seq", changed_since)
    for r in rows(db, "SELECT commit_sha, measured_at, codecov, coveralls FROM coverage" * where, params)
        out[String(r.commit_sha)] = SortedDict("coveralls" => js(r.coveralls), "codecov" => js(r.codecov), "date" => js(r.measured_at))
    end
    return out
end

"The timing extract: all history, with the per-job statistics."
timing_file(db) = SortedDict("coverage" => coverage(db), "generated_at" => generated_at(db, "timing"),
                             "jobs" => timing_jobs(db; stats=true))

"The API's timing window; `change_seq` is the cursor for the next incremental refresh."
function timing(db; since="", until="", changed_since=0)
    # The cursor is read before the rows: an ingest landing in between is
    # then fetched again by the next refresh rather than skipped for good
    seq = Store.current_seq(db)
    builds = Dict{String,Any}()
    jobs = timing_jobs(db; since, until, changed_since, builds)
    return OrderedDict(
        "generated_at" => generated_at(db, "timing"), "change_seq" => seq,
        "since" => since, "until" => until, "builds" => builds, "jobs" => jobs, "coverage" => coverage(db; changed_since))
end

seconds_between(a, b) = (a === missing || b === missing) ? nothing : round((DateTime(String(b), Store.ISO_SECONDS) - DateTime(String(a), Store.ISO_SECONDS)).value / 1000; digits=1)

# Builds with their wall time and the queue wait of their jobs (time from
# runnable to started), newest first. Only builds fetched from the API have
# the timestamps; legacy rows are left out.
function timing_builds(db; since="")
    where, params = where_clause("b.created_at", since, "")
    builds = OrderedDict{Int,Any}()
    for b in rows(db, "SELECT id, pipeline, number, commit_prefix, author, message, state, created_at, started_at, finished_at, web_url " *
                      "FROM builds b" * where * (isempty(where) ? " WHERE" : " AND") * " b.started_at IS NOT NULL ORDER BY b.created_at DESC", params)
        builds[Int(b.id)] = OrderedDict{String,Any}(
            "pipeline" => String(b.pipeline), "build" => Int(b.number), "commit" => String(b.commit_prefix),
            "author" => String(b.author), "message" => String(b.message), "state" => jstr(b.state),
            "created_at" => String(b.created_at), "started_at" => jstr(b.started_at), "finished_at" => jstr(b.finished_at),
            "url" => js(b.web_url), "wall_s" => seconds_between(b.started_at, b.finished_at),
            "jobs" => 0, "run_total_s" => 0.0, "queue_waits" => Float64[])
    end
    isempty(builds) && return Any[]
    for j in rows(db, "SELECT build_id, duration_s, runnable_at, started_at FROM jobs WHERE build_id IN (SELECT value FROM json_each(?))",
                  (JSON3.write(collect(keys(builds))),))
        b = builds[Int(j.build_id)]
        b["jobs"] += 1
        b["run_total_s"] += Float64(j.duration_s)
        w = seconds_between(j.runnable_at, j.started_at)
        w === nothing || push!(b["queue_waits"], w)
    end
    for b in values(builds)
        w = sort!(b["queue_waits"])
        b["queue_median_s"] = isempty(w) ? nothing : round(median(w); digits=1)
        b["queue_max_s"] = isempty(w) ? nothing : w[end]
        b["queue_total_s"] = round(sum(w; init=0.0); digits=1)
        b["run_total_s"] = round(b["run_total_s"]; digits=1)
        delete!(b, "queue_waits")
    end
    return collect(values(builds))
end

# --- benchmarks --------------------------------------------------------------

date_path(path) = replace(path, "by_date/" => "")

const BENCH_METRICS = Dict("time" => "time_ns", "gctime" => "gctime_ns", "memory" => "memory_bytes", "allocs" => "allocs")

const BENCH_GROUP_COLUMNS = Dict("time" => ("geomean_ns", "count"), "gctime" => ("gctime_geomean_ns", "gctime_count"),
                                 "memory" => ("memory_geomean_bytes", "memory_count"), "allocs" => ("allocs_geomean", "allocs_count"))

# Per (report, group, statistic) geomean and count of a metric, as the
# fetcher summarized them
function bench_group_geomeans(db, metric)
    geomean, count = BENCH_GROUP_COLUMNS[metric]
    return rows(db, "SELECT report_id, grp, stat, $geomean AS geomean, $count AS count FROM bench_report_groups " *
                    "WHERE stat IN ('minimum', 'mean') AND $count > 0")
end

function bench_summary(db; metric="time")
    reports = rows(db, "SELECT id, date, path, commit_sha, baseline_date, report_total, report_regressions, report_improvements " *
                       "FROM bench_reports WHERE kind = 'daily' ORDER BY date")
    # The files carry the two legacy statistics; median and std stay in the database
    by_report = Dict{Int,Dict{String,Dict{String,Any}}}()
    for g in bench_group_geomeans(db, metric)
        d = get!(by_report, Int(g.report_id), Dict{String,Dict{String,Any}}())
        e = get!(d, String(g.grp), Dict{String,Any}())
        e["$(g.stat)_geomean_ns"] = Float64(g.geomean)
        e["$(g.stat)_count"] = Int(g.count)
    end
    out = Any[]
    for r in reports
        e = OrderedDict{String,Any}("date" => String(r.date), "date_path" => date_path(String(r.path)),
                                    "commit" => String(r.commit_sha), "by_group" => get(by_report, Int(r.id), Dict()))
        r.report_total === missing || (e["report_total"] = Int(r.report_total))
        r.report_regressions === missing || (e["report_regressions"] = Int(r.report_regressions))
        r.report_improvements === missing || (e["report_improvements"] = Int(r.report_improvements))
        r.baseline_date === missing || (e["report_baseline_date"] = String(r.baseline_date))
        push!(out, e)
    end
    return OrderedDict("generated_at" => generated_at(db, "benchmarks"), "metric" => metric, "reports" => out)
end

bench_groups(db) = String[String(r.grp) for r in rows(db, "SELECT DISTINCT grp FROM bench_names ORDER BY grp")]

# One group's detail: per statistic, every benchmark's series over the
# reports that have a summary row for the (group, statistic), aligned with
# `dates`. `since` bounds the report date; `metric` picks the estimate
# (time by default; gctime, memory and allocs exist where the report
# tarball was parsed, not for rows imported from the legacy files).
function bench_group(db, grp; since="", metric="time")
    column = BENCH_METRICS[metric]
    names = rows(db, "SELECT id, name FROM bench_names WHERE grp = ? ORDER BY name", (grp,))
    detail = OrderedDict{String,Any}()
    for stat in ("minimum", "mean")
        reports = rows(db, "SELECT r.id, r.date, r.path, r.commit_sha FROM bench_report_groups g JOIN bench_reports r ON r.id = g.report_id " *
                           "WHERE g.grp = ? AND g.stat = ? AND r.kind = 'daily'" * (isempty(since) ? "" : " AND r.date >= ?") * " ORDER BY r.date",
                       isempty(since) ? (grp, stat) : (grp, stat, since))
        ids = Int[Int(r.id) for r in reports]
        pos = Dict(id => i for (i, id) in enumerate(ids))
        series = OrderedDict{String,Vector{Union{Nothing,Float64}}}()
        bench_by_id = Dict{Int,Vector{Union{Nothing,Float64}}}()
        for n in names
            v = Vector{Union{Nothing,Float64}}(nothing, length(ids))
            series[String(n.name)] = v
            bench_by_id[Int(n.id)] = v
        end
        if !isempty(ids)
            # The report list is a JSON array parameter: a window is a few
            # reports out of hundreds, and the primary key serves the lookups
            for r in DBInterface.execute(db, "SELECT r.report_id, r.bench_id, r.$column AS value FROM bench_results r " *
                                             "WHERE r.stat = ? AND r.bench_id IN (SELECT id FROM bench_names WHERE grp = ?) " *
                                             "AND r.report_id IN (SELECT value FROM json_each(?))", (stat, grp, JSON3.write(ids)))
                i = get(pos, Int(r.report_id), nothing)
                (i === nothing || r.value === missing) && continue
                bench_by_id[Int(r.bench_id)][i] = Float64(r.value)
            end
        end
        detail[stat] = OrderedDict("benchmarks" => series,
                                   "dates" => [String(r.date) for r in reports],
                                   "date_paths" => [date_path(String(r.path)) for r in reports],
                                   "commits" => [String(r.commit_sha) for r in reports])
    end
    return detail
end

# Nanosoldier's verdicts (report.md) for the daily reports since a date:
# the benchmarks it flagged as regressions or improvements against the
# baseline, with the time and memory ratios.
function bench_verdicts(db; since="")
    where, params = where_clause("r.date", since, "")
    out = Any[]
    for v in rows(db, "SELECT r.date, r.path, r.commit_sha, r.baseline_date, n.grp, n.name, v.verdict, " *
                      "v.time_ratio, v.time_tolerance, v.memory_ratio, v.memory_tolerance " *
                      "FROM bench_verdicts v JOIN bench_reports r ON r.id = v.report_id JOIN bench_names n ON n.id = v.bench_id" *
                      where * (isempty(where) ? " WHERE" : " AND") * " r.kind = 'daily' AND v.verdict IN ('regression', 'improvement') " *
                      "ORDER BY r.date DESC, n.grp, n.name", params)
        push!(out, OrderedDict("date" => String(v.date), "date_path" => date_path(String(v.path)), "commit" => String(v.commit_sha),
                               "baseline_date" => js(v.baseline_date), "group" => String(v.grp), "name" => String(v.name),
                               "verdict" => String(v.verdict), "time_ratio" => js(v.time_ratio), "time_tolerance" => js(v.time_tolerance),
                               "memory_ratio" => js(v.memory_ratio), "memory_tolerance" => js(v.memory_tolerance)))
    end
    return OrderedDict("generated_at" => generated_at(db, "benchmarks"), "since" => since, "verdicts" => out)
end

# --- pkgeval -----------------------------------------------------------------

# Package names matching a prefix (case-insensitive), for a search box
function pkgeval_packages(db, q; limit=25)
    isempty(q) && return String[]
    return String[String(r.name) for r in rows(db, "SELECT name FROM packages WHERE name LIKE ? ESCAPE '\\' ORDER BY length(name), name LIMIT ?",
                                                (replace(q, "%" => "\\%", "_" => "\\_") * "%", limit))]
end

# One package's status on every daily report that has package rows
function pkgeval_package(db, name)
    history = Any[]
    for r in rows(db, "SELECT r.date, r.path, r.julia_version, p.version, p.status, p.reason, p.duration_s " *
                      "FROM pkgeval_results p JOIN packages k ON k.id = p.package_id JOIN pkgeval_reports r ON r.id = p.report_id " *
                      "WHERE k.name = ? AND r.kind = 'daily' ORDER BY r.date", (name,))
        push!(history, OrderedDict("date" => String(r.date), "date_path" => date_path(String(r.path)), "julia" => String(r.julia_version),
                                   "version" => js(r.version), "status" => String(r.status), "reason" => js(r.reason),
                                   "duration_s" => js(r.duration_s)))
    end
    return OrderedDict("name" => name, "history" => history)
end

# Status and reason counts of one report (the newest with package rows by default)
function pkgeval_reasons(db, path="")
    r = if isempty(path)
        rows(db, "SELECT r.id, r.date, r.path FROM pkgeval_reports r WHERE r.kind = 'daily' AND EXISTS " *
                 "(SELECT 1 FROM pkgeval_reasons x WHERE x.report_id = r.id) ORDER BY r.date DESC LIMIT 1")
    else
        rows(db, "SELECT id, date, path FROM pkgeval_reports WHERE path = ?", ("by_date/" * path,))
    end
    isempty(r) && return nothing
    reasons = [OrderedDict("status" => String(x.status), "reason" => String(x.reason), "count" => Int(x.count))
               for x in rows(db, "SELECT status, reason, count FROM pkgeval_reasons WHERE report_id = ? ORDER BY count DESC", (Int(r[1].id),))]
    return OrderedDict("date" => String(r[1].date), "date_path" => date_path(String(r[1].path)), "reasons" => reasons)
end

# Packages that did not pass the newest report with package rows, ranked by
# their downloads over the last `days` days of rollups: the failures that
# matter most. `rank` is the package's place among every package by the
# same downloads, so a caller can say "the 12th most downloaded package".
function pkgeval_popular(db; days=30, limit=50, client="user", statuses=("fail", "crash", "skip"))
    report = rows(db, "SELECT r.id, r.date, r.path FROM pkgeval_reports r WHERE r.kind = 'daily' AND EXISTS " *
                      "(SELECT 1 FROM pkgeval_results x WHERE x.report_id = r.id) ORDER BY r.date DESC LIMIT 1")
    isempty(report) && return nothing
    last = rows(db, "SELECT MAX(date) AS d FROM dl_packages")
    (isempty(last) || last[1].d === missing) && return nothing
    until = String(last[1].d)
    since = Dates.format(Date(until) - Day(days - 1), dateformat"yyyy-mm-dd")
    metric = client == "all" ? "total" : client
    status_list = JSON3.write(collect(statuses))
    packages = [OrderedDict("rank" => Int(r.rank), "name" => String(r.name), "status" => String(r.status), "reason" => js(r.reason),
                            "version" => js(r.version), "all" => Int(r.total), "user" => Int(r.user), "ci" => Int(r.ci))
                for r in rows(db, "WITH dl AS (SELECT g.name, SUM(d.request_count) AS total, " *
                                  "SUM(CASE WHEN d.client_type = 'user' THEN d.request_count ELSE 0 END) AS user, " *
                                  "SUM(CASE WHEN d.client_type = 'ci' THEN d.request_count ELSE 0 END) AS ci " *
                                  "FROM dl_packages d JOIN dl_package_uuids u ON u.id = d.package_id JOIN registry_packages g ON g.uuid = u.uuid " *
                                  "WHERE d.date >= ? AND d.date <= ? GROUP BY g.name), " *
                                  "ranked AS (SELECT name, total, user, ci, RANK() OVER (ORDER BY $metric DESC) AS rank FROM dl) " *
                                  "SELECT ranked.rank, k.name, p.status, p.reason, p.version, ranked.total, ranked.user, ranked.ci " *
                                  "FROM pkgeval_results p JOIN packages k ON k.id = p.package_id JOIN ranked ON ranked.name = k.name " *
                                  "WHERE p.report_id = ? AND p.status IN (SELECT value FROM json_each(?)) " *
                                  "ORDER BY ranked.rank LIMIT ?", (since, until, Int(report[1].id), status_list, limit))]
    return OrderedDict("date" => String(report[1].date), "date_path" => date_path(String(report[1].path)),
                       "days" => days, "since" => since, "until" => until, "client" => client, "packages" => packages)
end

function pkgeval(db)
    reports = Any[]
    for r in rows(db, "SELECT date, path, commit_sha, julia_version, total, ok, fail, crash, skip, kill " *
                      "FROM pkgeval_reports WHERE kind = 'daily' ORDER BY date")
        push!(reports, OrderedDict("date" => String(r.date), "date_path" => date_path(String(r.path)),
                                   "total" => Int(r.total), "ok" => Int(r.ok), "fail" => Int(r.fail), "crash" => Int(r.crash),
                                   "skip" => Int(r.skip), "kill" => Int(r.kill), "version" => String(r.julia_version),
                                   "commit" => first(String(r.commit_sha), 8)))
    end
    return OrderedDict("generated_at" => generated_at(db, "pkgeval"), "reports" => reports)
end

# --- ttfx --------------------------------------------------------------------

const TTFX_METRICS = ["precompile", "load", "run", "warm", "load_gcoff", "run_gcoff", "warm_gcoff"]

function ttfx(db; since="")
    results = Dict{String,Dict{String,Any}}()
    for r in rows(db, "SELECT job_uuid, task, precompile, load, run, warm, load_gcoff, run_gcoff, warm_gcoff FROM ttfx_results")
        vals = Any[js(getproperty(r, Symbol(m))) for m in TTFX_METRICS]
        get!(results, String(r.job_uuid), Dict{String,Any}())[String(r.task)] = vals
    end
    failures = Dict{String,Dict{String,String}}()
    for r in rows(db, "SELECT job_uuid, task, error FROM ttfx_failures")
        get!(failures, String(r.job_uuid), Dict{String,String}())[String(r.task)] = String(r.error)
    end
    builds = Any[]
    pipeline = "julia-ci"
    where, params = where_clause("build_created_at", since, "")
    for j in rows(db, "SELECT * FROM ttfx_jobs" * where * " ORDER BY build_created_at, build", params)
        pipeline = String(j.pipeline)
        tasks = get(results, String(j.job_uuid), Dict{String,Any}())
        n = Int(j.n_metrics)
        push!(builds, Dict{String,Any}(
            "build" => Int(j.build), "job_id" => String(j.job_uuid), "triplet" => String(j.triplet), "state" => String(j.state),
            "date" => iso_to_legacy_minute(String(j.build_created_at)), "commit" => String(j.commit_sha),
            "version" => String(j.version), "message" => String(j.message), "agent" => String(j.agent), "cpu" => String(j.cpu),
            "snippets" => String(j.snippets), "blocks" => js(j.blocks), "n_tasks" => js(j.n_tasks),
            "tasks" => Dict(k => v[1:n] for (k, v) in tasks),
            "failed" => get(failures, String(j.job_uuid), Dict{String,String}())))
    end
    task_names = sort!(unique(String[k for b in builds for d in (b["tasks"], b["failed"]) for k in keys(d)]))
    return OrderedDict("generated_at" => generated_at(db, "ttfx"), "pipeline" => pipeline, "branch" => "master",
                       "metrics" => TTFX_METRICS, "tasks" => task_names, "builds" => builds)
end

# --- downloads ---------------------------------------------------------------

const DL_SOURCE = "https://julialang-logs.s3.amazonaws.com/public_outputs/current/resource_types_by_date.csv.gz"
const DL_VERSIONS_SOURCE = "https://julialang-logs.s3.amazonaws.com/public_outputs/current/julia_versions_by_date.csv.gz"
const DL_TAGS_SOURCE = "https://api.github.com/repos/JuliaLang/julia/releases"

function downloads(db)
    series = [OrderedDict("date" => String(r.date), "all" => Int(r.total_requests), "user" => Int(r.user_requests), "ci" => Int(r.ci_requests))
              for r in rows(db, "SELECT date, total_requests, user_requests, ci_requests FROM dl_series ORDER BY date")]
    counts(r) = OrderedDict("all" => Int(r.total_requests), "user" => Int(r.user_requests), "ci" => Int(r.ci_requests))
    function mix(kind, member)
        per_date = OrderedDict{String,Any}()
        for r in rows(db, "SELECT date, key, total_requests, user_requests, ci_requests FROM dl_mix WHERE kind = ? ORDER BY date, key", (kind,))
            e = get!(per_date, String(r.date)) do
                OrderedDict("date" => String(r.date), "totals" => nothing, member => OrderedDict{String,Any}())
            end
            if r.key == "*"
                e["totals"] = counts(r)
            else
                e[member][String(r.key)] = counts(r)
            end
        end
        return collect(values(per_date))
    end
    tag(r) = OrderedDict("tag" => String(r.tag), "date" => String(r.date), "published_at" => String(r.published_at), "url" => String(r.url))
    # The fetcher lists releases of the last two years; the table keeps them all
    tag_cutoff = Dates.format(Date(now(UTC)) - Year(2), dateformat"yyyy-mm-dd")
    tags(pre) = [tag(r) for r in rows(db, "SELECT tag, date, published_at, url FROM julia_tags WHERE prerelease = ? AND date >= ? " *
                                          "ORDER BY date, published_at DESC", (pre, tag_cutoff))]
    return OrderedDict(
        "generated_at" => generated_at(db, "packages"),
        "source" => DL_SOURCE,
        "julia_versions_source" => DL_VERSIONS_SOURCE,
        "julia_tags_source" => DL_TAGS_SOURCE,
        "julia_tags_window_years" => 2,
        "julia_tags" => tags(0),
        "julia_prerelease_tags" => tags(1),
        "maxDate" => isempty(series) ? nothing : series[end]["date"],
        "series" => series,
        "version_mix" => mix("version", "minors"),
        "version_stage_mix" => mix("stage", "channels"))
end

# Registry names matching a prefix, for a search box; only packages with requests
function download_packages(db, q; limit=25)
    isempty(q) && return String[]
    return String[String(r.name) for r in rows(db, "SELECT DISTINCT g.name FROM registry_packages g JOIN dl_package_uuids u ON u.uuid = g.uuid " *
                                                "WHERE g.name LIKE ? ESCAPE '\\' ORDER BY length(g.name), g.name LIMIT ?",
                                                (replace(q, "%" => "\\%", "_" => "\\_") * "%", limit))]
end

counts_row(r) = OrderedDict("all" => Int(r.all), "user" => Int(r.user), "ci" => Int(r.ci))

# Daily successful requests for one package, user and CI clients apart
function download_package(db, name)
    series = [OrderedDict("date" => String(r.date), "all" => Int(r.all), "user" => Int(r.user), "ci" => Int(r.ci))
              for r in rows(db, "SELECT d.date, SUM(d.request_count) AS `all`, " *
                                "SUM(CASE WHEN d.client_type = 'user' THEN d.request_count ELSE 0 END) AS user, " *
                                "SUM(CASE WHEN d.client_type = 'ci' THEN d.request_count ELSE 0 END) AS ci " *
                                "FROM dl_packages d JOIN dl_package_uuids u ON u.id = d.package_id JOIN registry_packages g ON g.uuid = u.uuid " *
                                "WHERE g.name = ? GROUP BY d.date ORDER BY d.date", (name,))]
    return OrderedDict("name" => name, "series" => series)
end

# The most requested packages over the last `days` days of data
function download_top(db; days=7, limit=50, client="user")
    last = rows(db, "SELECT MAX(date) AS d FROM dl_packages")
    (isempty(last) || last[1].d === missing) && return OrderedDict("days" => days, "since" => nothing, "until" => nothing, "packages" => Any[])
    until = String(last[1].d)
    since = Dates.format(Date(until) - Day(days - 1), dateformat"yyyy-mm-dd")
    metric = client == "all" ? "SUM(d.request_count)" : "SUM(CASE WHEN d.client_type = '$client' THEN d.request_count ELSE 0 END)"
    packages = [OrderedDict("name" => js(r.name), "uuid" => String(r.uuid), "all" => Int(r.all), "user" => Int(r.user), "ci" => Int(r.ci))
                for r in rows(db, "SELECT g.name, u.uuid, SUM(d.request_count) AS `all`, " *
                                  "SUM(CASE WHEN d.client_type = 'user' THEN d.request_count ELSE 0 END) AS user, " *
                                  "SUM(CASE WHEN d.client_type = 'ci' THEN d.request_count ELSE 0 END) AS ci " *
                                  "FROM dl_packages d JOIN dl_package_uuids u ON u.id = d.package_id LEFT JOIN registry_packages g ON g.uuid = u.uuid " *
                                  "WHERE d.date >= ? AND d.date <= ? GROUP BY u.uuid ORDER BY $metric DESC LIMIT ?", (since, until, limit))]
    return OrderedDict("days" => days, "since" => since, "until" => until, "client" => client, "packages" => packages)
end

# --- agents ------------------------------------------------------------------

const AGENT_RETAIN_MONTHS = 12

# Fixed field order, as the fetcher wrote it, so the file diffs cleanly
job_record(j) = OrderedDict{String,Any}("name" => get(j, :name, ""), "pipeline" => get(j, :pipeline, ""),
                                        "build" => get(j, :build, nothing), "started_at" => get(j, :started_at, ""))

"Time of the latest snapshot (the agents' generated_at), or the source's last run."
function agents_generated_at(db)
    r = rows(db, "SELECT MAX(time) AS t FROM agent_snapshots")
    return isempty(r) || r[1].t === missing ? generated_at(db, "agents") : String(r[1].t)
end

# The fetcher used to delete agents and month files older than a year;
# now the window is applied here, relative to the latest snapshot.
agents_cutoff(gen) = Store.iso(DateTime(gen, Store.ISO_SECONDS) - Month(AGENT_RETAIN_MONTHS))

function agents_latest(db)
    gen = agents_generated_at(db)
    records = OrderedDict{String,Any}()
    for a in rows(db, "SELECT * FROM agents WHERE last_seen >= ? ORDER BY name", (agents_cutoff(gen),))
        records[String(a.name)] = OrderedDict{String,Any}(
            "hostname" => String(a.hostname), "queue" => String(a.queue), "os" => String(a.os), "arch" => String(a.arch),
            "version" => String(a.version), "state" => String(a.state), "connected_at" => jstr(a.connected_at),
            "first_seen" => jstr(a.first_seen), "last_seen" => jstr(a.last_seen),
            "job" => a.job_json === missing ? nothing : job_record(JSON3.read(String(a.job_json))))
    end
    return OrderedDict{String,Any}("generated_at" => gen, "agents" => records)
end

"Snapshots from `since` on (all retained ones by default), oldest first."
function agent_snapshots(db; since="")
    since = isempty(since) ? agents_cutoff(agents_generated_at(db)) : since
    members = Dict{String,Vector{String}}()
    for r in rows(db, "SELECT time, agent_name FROM agent_snapshot_members WHERE time >= ? ORDER BY time, agent_name", (since,))
        push!(get!(members, String(r.time), String[]), String(r.agent_name))
    end
    return [OrderedDict("time" => String(r.time), "connected" => get(members, String(r.time), String[]))
            for r in rows(db, "SELECT time FROM agent_snapshots WHERE time >= ? ORDER BY time", (since,))]
end

# --- health --------------------------------------------------------------------

# Percent of the volume holding the database in use (df), or nothing
function disk_used_pct(db)
    try
        lines = split(read(`df -P $(dirname(abspath(db.file)))`, String), '\n'; keepempty=false)
        length(lines) >= 2 || return nothing
        return parse(Int, rstrip(split(lines[end])[5], '%'))
    catch
        return nothing
    end
end

# The newest instant or day each source has data for: a run that succeeds
# without storing anything (an upstream returning nothing) shows here.
const LATEST_DATA = Dict(
    "timing" => "SELECT MAX(created_at) AS t FROM builds",
    "benchmarks" => "SELECT MAX(date) AS t FROM bench_reports",
    "pkgeval" => "SELECT MAX(date) AS t FROM pkgeval_reports",
    "ttfx" => "SELECT MAX(build_created_at) AS t FROM ttfx_jobs",
    "packages" => "SELECT MAX(date) AS t FROM dl_series",
    "agents" => "SELECT MAX(time) AS t FROM agent_snapshots")

# /healthz for monitoring: the latest run and latest success per source,
# the newest data each holds, and the disk.
function health(db)
    sources = OrderedDict{String,Any}()
    for r in rows(db, "SELECT source, MAX(CASE WHEN ok = 1 THEN finished_at END) AS last_ok_at, MAX(started_at) AS last_run_at " *
                      "FROM source_runs GROUP BY source ORDER BY source")
        source = String(r.source)
        last = rows(db, "SELECT ok, rows_written, error, finished_at FROM source_runs WHERE source = ? ORDER BY id DESC LIMIT 1", (source,))[1]
        latest = haskey(LATEST_DATA, source) ? js(rows(db, LATEST_DATA[source])[1].t) : nothing
        sources[source] = OrderedDict("last_ok_at" => js(r.last_ok_at), "last_run_at" => js(r.last_run_at),
                                      "last_ok" => last.ok === missing ? nothing : last.ok == 1,
                                      "last_rows" => js(last.rows_written), "last_error" => js(last.error),
                                      "latest_data" => latest)
    end
    return OrderedDict("generated_at" => Store.iso_now(), "change_seq" => Store.current_seq(db),
                       "disk_used_pct" => disk_used_pct(db), "sources" => sources)
end

end # module
