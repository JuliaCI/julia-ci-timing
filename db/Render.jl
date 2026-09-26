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
# Alongside: how many of the `top_n` most downloaded are not passing, the
# share of downloads going to passing packages (with a history over the
# reports of the past year, weighted by today's downloads), and the
# packages that passed the previous report but not this one. Each listed
# package carries how long it has been failing (`failing_runs`). The weighting
# counts the `PKGEVAL_WEIGHT_N` most downloaded packages, which carry
# nearly all downloads; over every package the year's history takes five
# seconds instead of under one.
const PKGEVAL_TOP_N = 100
const PKGEVAL_WEIGHT_N = 2000

# Each package's current run of failures: the first daily report after the
# last one it passed (or its first report with package rows, when it never
# passed; `last_passed` is then null and the run may be longer), and how
# many reports the run spans
function failing_runs(db, names)
    out = Dict{String,Any}()
    isempty(names) && return out
    for r in rows(db, "WITH k AS (SELECT id, name FROM packages WHERE name IN (SELECT value FROM json_each(?))), " *
                      "h AS (SELECT k.name, r.date, p.status FROM k JOIN pkgeval_results p ON p.package_id = k.id " *
                      "JOIN pkgeval_reports r ON r.id = p.report_id WHERE r.kind = 'daily'), " *
                      "ok AS (SELECT name, MAX(date) AS d FROM h WHERE status = 'ok' GROUP BY name) " *
                      "SELECT h.name, MIN(h.date) AS since, COUNT(*) AS n, ok.d AS last_passed FROM h LEFT JOIN ok ON ok.name = h.name " *
                      "WHERE ok.d IS NULL OR h.date > ok.d GROUP BY h.name", (JSON3.write(names),))
        out[String(r.name)] = Dict("failing_since" => String(r.since), "failing_reports" => Int(r.n), "last_passed" => js(r.last_passed))
    end
    return out
end

function pkgeval_popular(db; days=30, limit=50, client="user", statuses=("fail", "crash", "skip"))
    reports = rows(db, "SELECT r.id, r.date, r.path FROM pkgeval_reports r WHERE r.kind = 'daily' AND EXISTS " *
                       "(SELECT 1 FROM pkgeval_results x WHERE x.report_id = r.id) ORDER BY r.date DESC LIMIT 2")
    isempty(reports) && return nothing
    last = rows(db, "SELECT MAX(date) AS d FROM dl_packages")
    (isempty(last) || last[1].d === missing) && return nothing
    until = String(last[1].d)
    since = Dates.format(Date(until) - Day(days - 1), dateformat"yyyy-mm-dd")
    metric = client == "all" ? "total" : client
    report_id = Int(reports[1].id)
    # Downloads per registry package name over the window, ranked
    dl = "WITH dl AS (SELECT g.name, SUM(d.request_count) AS total, " *
         "SUM(CASE WHEN d.client_type = 'user' THEN d.request_count ELSE 0 END) AS user, " *
         "SUM(CASE WHEN d.client_type = 'ci' THEN d.request_count ELSE 0 END) AS ci " *
         "FROM dl_packages d JOIN dl_package_uuids u ON u.id = d.package_id JOIN registry_packages g ON g.uuid = u.uuid " *
         "WHERE d.date >= ? AND d.date <= ? GROUP BY g.name), " *
         "ranked AS (SELECT name, total, user, ci, RANK() OVER (ORDER BY $metric DESC) AS rank FROM dl) "
    packages = [OrderedDict("rank" => Int(r.rank), "name" => String(r.name), "status" => String(r.status), "reason" => js(r.reason),
                            "version" => js(r.version), "all" => Int(r.total), "user" => Int(r.user), "ci" => Int(r.ci))
                for r in rows(db, dl * "SELECT ranked.rank, k.name, p.status, p.reason, p.version, ranked.total, ranked.user, ranked.ci " *
                                  "FROM pkgeval_results p JOIN packages k ON k.id = p.package_id JOIN ranked ON ranked.name = k.name " *
                                  "WHERE p.report_id = ? AND p.status IN (SELECT value FROM json_each(?)) " *
                                  "ORDER BY ranked.rank LIMIT ?", (since, until, report_id, JSON3.write(collect(statuses)), limit))]
    # How long each has been failing
    runs = failing_runs(db, [p["name"] for p in packages])
    for p in packages
        merge!(p, get(runs, p["name"], Dict("failing_since" => nothing, "failing_reports" => 0, "last_passed" => nothing)))
    end
    # Of the top N by these downloads that the report tested, how many are not ok
    top = rows(db, dl * "SELECT COUNT(*) AS tested, SUM(CASE WHEN p.status != 'ok' THEN 1 ELSE 0 END) AS not_ok " *
                        "FROM ranked JOIN packages k ON k.name = ranked.name JOIN pkgeval_results p ON p.package_id = k.id AND p.report_id = ? " *
                        "WHERE ranked.rank <= ?", (since, until, report_id, PKGEVAL_TOP_N))[1]
    # Downloads to tested packages, and the share of them going to passing ones
    w = rows(db, dl * "SELECT SUM(ranked.$metric) AS total, SUM(CASE WHEN p.status = 'ok' THEN ranked.$metric ELSE 0 END) AS ok " *
                      "FROM ranked JOIN packages k ON k.name = ranked.name JOIN pkgeval_results p ON p.package_id = k.id AND p.report_id = ? " *
                      "WHERE ranked.rank <= ?", (since, until, report_id, PKGEVAL_WEIGHT_N))[1]
    pass_pct(x) = x.total === missing || x.total == 0 ? nothing : round(100 * Float64(x.ok) / Float64(x.total); digits=1)
    # The same share on every report of the past year, weighted by today's downloads
    year_ago = Dates.format(Date(String(reports[1].date)) - Year(1), dateformat"yyyy-mm-dd")
    history = [OrderedDict("date" => String(r.date), "pass_pct" => pass_pct(r))
               for r in rows(db, dl * "SELECT r.date, SUM(ranked.$metric) AS total, SUM(CASE WHEN p.status = 'ok' THEN ranked.$metric ELSE 0 END) AS ok " *
                                      "FROM pkgeval_reports r JOIN pkgeval_results p ON p.report_id = r.id " *
                                      "JOIN packages k ON k.id = p.package_id JOIN ranked ON ranked.name = k.name " *
                                      "WHERE ranked.rank <= ? AND r.kind = 'daily' AND r.date >= ? GROUP BY r.id ORDER BY r.date",
                                  (since, until, PKGEVAL_WEIGHT_N, year_ago))]
    # Passed the previous report, not this one: the nightly breakage
    newly_broken = Any[]
    previous = nothing
    if length(reports) == 2
        previous = String(reports[2].date)
        newly_broken = [OrderedDict("rank" => Int(r.rank), "name" => String(r.name), "status" => String(r.status), "reason" => js(r.reason),
                                    "user" => Int(r.user))
                        for r in rows(db, dl * "SELECT ranked.rank, k.name, p.status, p.reason, ranked.user " *
                                          "FROM pkgeval_results p JOIN packages k ON k.id = p.package_id JOIN ranked ON ranked.name = k.name " *
                                          "JOIN pkgeval_results q ON q.package_id = p.package_id AND q.report_id = ? " *
                                          "WHERE p.report_id = ? AND p.status != 'ok' AND q.status = 'ok' ORDER BY ranked.rank LIMIT ?",
                                      (since, until, Int(reports[2].id), report_id, limit))]
    end
    return OrderedDict("date" => String(reports[1].date), "date_path" => date_path(String(reports[1].path)),
                       "days" => days, "since" => since, "until" => until, "client" => client, "packages" => packages,
                       "top_n" => PKGEVAL_TOP_N, "top_tested" => Int(top.tested), "top_not_ok" => top.not_ok === missing ? 0 : Int(top.not_ok),
                       "weight_n" => PKGEVAL_WEIGHT_N, "weighted_pass_pct" => pass_pct(w), "history" => history,
                       "previous_date" => previous, "newly_broken" => newly_broken)
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

# Open pull requests by how their latest TTFX comparison looks, best first.
# The score multiplies, over precompile, load, run and warm, the suite geomean
# ratio (head/base) of the least favourable block: below 1 is faster, and
# one noisy block cannot carry a pull request up the list.
const TTFX_PR_METRICS = ["precompile", "load", "run", "warm"]

function ttfx_prs(db)
    prs = Any[]
    for r in rows(db, "SELECT * FROM ttfx_prs")
        suite = JSON3.read(String(r.suite))
        worst = [maximum(suite[m].geomeans) for m in TTFX_PR_METRICS if haskey(suite, m) && !isempty(suite[m].geomeans)]
        push!(prs, OrderedDict(
            "pr" => Int(r.pr_number), "title" => String(r.title), "author" => String(r.author), "draft" => r.draft == 1,
            "score" => isempty(worst) ? nothing : prod(worst), "verdict" => String(r.verdict),
            "n_improvements" => Int(r.n_improvements), "n_regressions" => Int(r.n_regressions),
            "suite" => suite, "tasks" => JSON3.read(String(r.tasks)),
            "build" => Int(r.build), "job_id" => String(r.job_uuid), "state" => String(r.job_state), "web_url" => js(r.web_url),
            "date" => String(r.build_created_at), "finished_at" => js(r.finished_at),
            "head" => OrderedDict("commit" => String(r.head_commit), "version" => String(r.head_version)),
            "base" => OrderedDict("commit" => String(r.base_commit), "version" => String(r.base_version)),
            "outdated" => String(r.pr_head_sha) != String(r.head_commit),
            # CI on the pull request's current head, which may be newer than the measured commit
            "ci" => r.ci_state === missing || !isequal(r.ci_commit, r.pr_head_sha) ? nothing :
                    OrderedDict("state" => String(r.ci_state), "build" => js(r.ci_build), "url" => js(r.ci_url)),
            "blocks" => js(r.blocks), "n_tasks" => js(r.n_tasks)))
    end
    sort!(prs; by=p -> (p["score"] === nothing, something(p["score"], 0.0), -p["n_improvements"], p["n_regressions"]))
    return OrderedDict("generated_at" => generated_at(db, "ttfx"), "pipeline" => "julia-pr", "metrics" => TTFX_PR_METRICS, "prs" => prs)
end

# --- commit lookup -------------------------------------------------------------

# Everything recorded about one julia commit, for the Commit view: its
# builds, its jobs' times and TTFX against the previous commit's, the
# Nanosoldier and PkgEval reports that first included it, and coverage.
# `ref` is a lowercase hex SHA prefix of 7 to 40 characters, or a PR number
# matched against the merge commit's subject ("... (#123)" or "Merge pull
# request #123 ..."; subjects are cut at 80 characters, so a long one can
# lose its number). Most builds only carry the 8-character prefix, so that
# is a commit's identity here. A ref matching several commits gets the list
# of them instead.
const COMMIT_LIST_LIMIT = 50
const COMMIT_PIPELINES = ("julia-ci", "julia-master", "julia-master-scheduled")
const SCHEDULED_MESSAGE = "Scheduled build"

pr_number(message) = (m = match(r"\(#(\d+)\)|^Merge pull request #(\d+) ", message); m === nothing ? nothing : parse(Int, something(m[1], m[2])))

# (prefix, sha) pairs, sha "" when no source has the full one
function commit_candidates(db, ref)
    found = OrderedDict{String,String}()
    note!(prefix, sha) = (sha = jstr(sha); get(found, prefix, "") == "" && (found[prefix] = length(sha) == 40 ? sha : ""))
    if (m = match(r"^(\d{1,6})$", ref)) !== nothing
        n = m[1]
        for b in rows(db, "SELECT commit_prefix, commit_sha FROM builds WHERE message GLOB ? OR message GLOB ? ORDER BY created_at",
                      ("*(#$n)*", "Merge pull request #$n *"))
            note!(String(b.commit_prefix), b.commit_sha)
        end
        return found
    end
    p8 = first(ref, 8)
    fits(sha) = sha === missing || length(sha) < length(ref) || startswith(String(sha), ref)
    for b in rows(db, "SELECT commit_prefix, commit_sha FROM builds WHERE commit_prefix GLOB ? ORDER BY created_at", (p8 * "*",))
        fits(b.commit_sha) && note!(String(b.commit_prefix), b.commit_sha)
    end
    for table in ("ttfx_jobs", "bench_reports", "pkgeval_reports")
        for r in rows(db, "SELECT DISTINCT commit_sha FROM $table WHERE commit_sha GLOB ? OR commit_sha = ?", (ref * "*", p8))
            sha = String(r.commit_sha)
            length(sha) >= 8 && note!(first(sha, 8), sha)
        end
    end
    return found
end

commit_glob(prefix, sha) = (isempty(sha) ? prefix : sha) * "*"

# When a commit's first build was created, the closest thing to its merge time
function commit_time(db, sha)
    length(sha) < 8 && return nothing
    r = rows(db, "SELECT MIN(created_at) AS t FROM builds WHERE commit_prefix = ?", (first(sha, 8),))
    return r[1].t === missing ? nothing : String(r[1].t)
end

function commit_summary(db, prefix, sha)
    b = rows(db, "SELECT commit_sha, author, message, created_at FROM builds WHERE commit_prefix = ? " *
                 "ORDER BY message = '$SCHEDULED_MESSAGE', created_at LIMIT 1", (prefix,))
    if isempty(b)
        t = rows(db, "SELECT message, build_created_at FROM ttfx_jobs WHERE commit_sha GLOB ? ORDER BY build_created_at LIMIT 1", (commit_glob(prefix, sha),))
        message = isempty(t) ? "" : String(t[1].message)
        return OrderedDict{String,Any}("prefix" => prefix, "sha" => sha, "author" => "", "message" => message,
                                       "pr" => pr_number(message), "created_at" => isempty(t) ? nothing : String(t[1].build_created_at))
    end
    message = String(b[1].message)
    return OrderedDict{String,Any}("prefix" => prefix, "sha" => isempty(sha) ? jstr(b[1].commit_sha) : sha, "author" => String(b[1].author),
                                   "message" => message, "pr" => pr_number(message), "created_at" => commit_time(db, prefix))
end

# The last attempt of every job of a build, by name
function last_attempts(jobs)
    out = Dict{String,Any}()
    for j in jobs
        name = String(j.name)
        (haskey(out, name) && out[name].retry >= j.retry) || (out[name] = j)
    end
    return out
end

function commit_builds(db, prefix, sha)
    out = Any[]
    for b in rows(db, "SELECT id, pipeline, number, commit_sha, state, message, created_at, started_at, finished_at, web_url " *
                      "FROM builds WHERE commit_prefix = ? ORDER BY created_at", (prefix,))
        (isempty(sha) || b.commit_sha === missing || String(b.commit_sha) == sha) || continue
        waits = Float64[]
        for j in rows(db, "SELECT runnable_at, started_at FROM jobs WHERE build_id = ?", (Int(b.id),))
            w = seconds_between(j.runnable_at, j.started_at)
            w === nothing || push!(waits, w)
        end
        prev = rows(db, "SELECT number, commit_prefix, state, started_at, finished_at FROM builds " *
                        "WHERE pipeline = ? AND number < ? AND commit_prefix != ? ORDER BY number DESC LIMIT 1", (b.pipeline, b.number, prefix))
        push!(out, OrderedDict{String,Any}(
            "id" => Int(b.id), "pipeline" => String(b.pipeline), "build" => Int(b.number), "commit" => prefix, "state" => jstr(b.state),
            "scheduled" => b.message == SCHEDULED_MESSAGE,
            "created_at" => String(b.created_at), "url" => js(b.web_url), "wall_s" => seconds_between(b.started_at, b.finished_at),
            "queue_median_s" => isempty(waits) ? nothing : round(median(waits); digits=1),
            "previous" => isempty(prev) ? nothing : OrderedDict(
                "build" => Int(prev[1].number), "commit" => String(prev[1].commit_prefix), "state" => jstr(prev[1].state),
                "wall_s" => seconds_between(prev[1].started_at, prev[1].finished_at))))
    end
    return out
end

# The build the view compares: the newest on the current pipeline, else the
# legacy ones, passing over scheduled rebuilds (they run a subset of the jobs)
# when the commit has another build
function primary_build(builds)
    for p in COMMIT_PIPELINES, scheduled in (false, true)
        i = findlast(b -> b["pipeline"] == p && b["scheduled"] == scheduled, builds)
        i === nothing || return builds[i]
    end
    return nothing
end

function neighbour(db, pipeline, number, prefix, dir)
    op, order = dir == :prev ? ("<", "DESC") : (">", "ASC")
    r = rows(db, "SELECT commit_prefix, message FROM builds WHERE pipeline = ? AND number $op ? AND commit_prefix != ? " *
                 "ORDER BY number $order LIMIT 1", (pipeline, number, prefix))
    return isempty(r) ? nothing : OrderedDict("commit" => String(r[1].commit_prefix), "message" => String(r[1].message))
end

# Every job of the build against the same job on the latest earlier build of
# another commit on the pipeline (the previous commit; a scheduled rebuild of
# the same commit does not count)
function commit_jobs(db, build)
    job_rows(id) = rows(db, "SELECT name, retry, state, duration_s, agent_hostname, web_url, soft_failed FROM jobs WHERE build_id = ?", (id,))
    current = last_attempts(job_rows(build["id"]))
    prev = rows(db, "SELECT id, number, commit_prefix FROM builds WHERE pipeline = ? AND number < ? AND commit_prefix != ? " *
                    "ORDER BY number DESC LIMIT 1", (build["pipeline"], build["build"], build["commit"]))
    before = isempty(prev) ? Dict{String,Any}() : last_attempts(job_rows(Int(prev[1].id)))
    jobs = Any[]
    for name in sort!(collect(keys(current)))
        j = current[name]
        p = get(before, name, nothing)
        push!(jobs, OrderedDict("name" => name, "state" => String(j.state), "soft_failed" => j.soft_failed === 1,
                                "duration_s" => round(Float64(j.duration_s); digits=1), "agent" => String(j.agent_hostname),
                                "url" => js(j.web_url), "previous_state" => p === nothing ? nothing : String(p.state),
                                "previous_s" => p === nothing ? nothing : round(Float64(p.duration_s); digits=1)))
    end
    return OrderedDict("pipeline" => build["pipeline"], "build" => build["build"],
                       "previous" => isempty(prev) ? nothing : OrderedDict("build" => Int(prev[1].number), "commit" => String(prev[1].commit_prefix)),
                       "jobs" => jobs)
end

# The TTFX job of the commit's build against the latest earlier one with
# results on another commit
function commit_ttfx(db, prefix, sha)
    tj = rows(db, "SELECT job_uuid, build, state, build_created_at, version, web_url FROM ttfx_jobs WHERE commit_sha GLOB ? " *
                  "ORDER BY build_created_at DESC LIMIT 1", (commit_glob(prefix, sha),))
    isempty(tj) && return nothing
    j = tj[1]
    prev = rows(db, "SELECT job_uuid, build, commit_sha FROM ttfx_jobs t WHERE build_created_at < ? AND commit_sha NOT GLOB ? AND EXISTS " *
                    "(SELECT 1 FROM ttfx_results r WHERE r.job_uuid = t.job_uuid) ORDER BY build_created_at DESC LIMIT 1",
                (j.build_created_at, commit_glob(prefix, sha)))
    metrics = TTFX_METRICS[1:4]
    results(uuid) = Dict(String(r.task) => Any[js(getproperty(r, Symbol(m))) for m in metrics]
                         for r in rows(db, "SELECT * FROM ttfx_results WHERE job_uuid = ?", (uuid,)))
    failures(uuid) = Dict(String(r.task) => String(r.error) for r in rows(db, "SELECT task, error FROM ttfx_failures WHERE job_uuid = ?", (uuid,)))
    now_ = results(String(j.job_uuid))
    failed = failures(String(j.job_uuid))
    before = isempty(prev) ? Dict{String,Any}() : results(String(prev[1].job_uuid))
    failed_before = isempty(prev) ? Dict{String,String}() : failures(String(prev[1].job_uuid))
    tasks = Any[]
    for task in sort!(unique([collect(keys(now_)); collect(keys(failed))]))
        push!(tasks, OrderedDict("task" => task, "now" => get(now_, task, nothing), "previous" => get(before, task, nothing),
                                 "failed" => get(failed, task, nothing), "failed_before" => haskey(failed_before, task)))
    end
    return OrderedDict("build" => Int(j.build), "job_id" => String(j.job_uuid), "state" => String(j.state), "version" => String(j.version),
                       "url" => js(j.web_url), "metrics" => metrics,
                       "previous" => isempty(prev) ? nothing : OrderedDict("build" => Int(prev[1].build), "commit" => first(String(prev[1].commit_sha), 8)),
                       "tasks" => tasks)
end

# The daily report run on the commit, or failing that the first one run on a
# later commit (by the time its first build was created), so the one whose
# range holds it
function first_report(db, table, prefix, sha, t)
    r = rows(db, "SELECT * FROM $table WHERE kind = 'daily' AND (commit_sha GLOB ? OR commit_sha = ?) ORDER BY date LIMIT 1",
             (commit_glob(prefix, sha), prefix))
    isempty(r) || return (r[1], "tested")
    t === nothing && return (nothing, nothing)
    day = first(t, 10)
    for c in rows(db, "SELECT * FROM $table WHERE kind = 'daily' AND date >= ? ORDER BY date LIMIT 5", (day,))
        ct = commit_time(db, String(c.commit_sha))
        (ct === nothing ? String(c.date) > day : ct >= t) && return (c, "included")
    end
    return (nothing, nothing)
end

function commit_benchmarks(db, prefix, sha, t)
    r, relation = first_report(db, "bench_reports", prefix, sha, t)
    r === nothing && return nothing
    verdicts = Any[]
    for v in rows(db, "SELECT n.grp, n.name, v.verdict, v.time_ratio, v.memory_ratio FROM bench_verdicts v JOIN bench_names n ON n.id = v.bench_id " *
                      "WHERE v.report_id = ? AND v.verdict IN ('regression', 'improvement')", (Int(r.id),))
        push!(verdicts, OrderedDict("group" => String(v.grp), "name" => String(v.name), "verdict" => String(v.verdict),
                                    "time_ratio" => js(v.time_ratio), "memory_ratio" => js(v.memory_ratio)))
    end
    sort!(verdicts; by=v -> v["time_ratio"] === nothing ? 0.0 : -abs(log(v["time_ratio"])))
    # How many commits the report's range spans, when both ends have builds
    t0 = r.baseline_commit_sha === missing ? nothing : commit_time(db, String(r.baseline_commit_sha))
    t1 = commit_time(db, String(r.commit_sha))
    in_range = (t0 === nothing || t1 === nothing) ? nothing :
        Int(rows(db, "SELECT COUNT(DISTINCT commit_prefix) AS n FROM builds WHERE pipeline IN ('julia-ci', 'julia-master') " *
                     "AND created_at > ? AND created_at <= ?", (t0, t1))[1].n)
    return OrderedDict("relation" => relation, "date" => String(r.date), "date_path" => date_path(String(r.path)),
                       "commit" => String(r.commit_sha), "baseline_commit" => js(r.baseline_commit_sha), "baseline_date" => js(r.baseline_date),
                       "julia_version" => js(r.julia_version), "total" => js(r.report_total), "regressions" => js(r.report_regressions),
                       "improvements" => js(r.report_improvements), "commits_in_range" => in_range,
                       "verdicts" => first(verdicts, COMMIT_LIST_LIMIT))
end

function commit_pkgeval(db, prefix, sha, t)
    r, relation = first_report(db, "pkgeval_reports", prefix, sha, t)
    r === nothing && return nothing
    counts(x) = OrderedDict(k => Int(getproperty(x, Symbol(k))) for k in ("total", "ok", "fail", "crash", "skip", "kill"))
    prev = rows(db, "SELECT * FROM pkgeval_reports WHERE kind = 'daily' AND date < ? ORDER BY date DESC LIMIT 1", (r.date,))
    broken = nothing
    n_broken = nothing
    if !isempty(prev)
        rs = rows(db, "SELECT k.name, p.status, p.reason FROM pkgeval_results p JOIN packages k ON k.id = p.package_id " *
                      "JOIN pkgeval_results q ON q.package_id = p.package_id AND q.report_id = ? " *
                      "WHERE p.report_id = ? AND p.status != 'ok' AND q.status = 'ok' ORDER BY k.name", (Int(prev[1].id), Int(r.id)))
        # Reports imported without package rows cannot say
        has_rows = !isempty(rows(db, "SELECT 1 FROM pkgeval_results WHERE report_id = ? LIMIT 1", (Int(r.id),))) &&
                   !isempty(rows(db, "SELECT 1 FROM pkgeval_results WHERE report_id = ? LIMIT 1", (Int(prev[1].id),)))
        if has_rows
            n_broken = length(rs)
            broken = [OrderedDict("name" => String(x.name), "status" => String(x.status), "reason" => js(x.reason))
                      for x in first(rs, COMMIT_LIST_LIMIT)]
        end
    end
    return OrderedDict("relation" => relation, "date" => String(r.date), "date_path" => date_path(String(r.path)),
                       "commit" => String(r.commit_sha), "julia_version" => String(r.julia_version), "counts" => counts(r),
                       "previous" => isempty(prev) ? nothing : OrderedDict("date" => String(prev[1].date), "counts" => counts(prev[1])),
                       "newly_broken_count" => n_broken, "newly_broken" => broken)
end

function commit_coverage(db, prefix, sha)
    c = rows(db, "SELECT * FROM coverage WHERE commit_sha GLOB ? LIMIT 1", (commit_glob(prefix, sha),))
    isempty(c) && return nothing
    p = c[1].measured_at === missing ? [] :
        rows(db, "SELECT * FROM coverage WHERE measured_at < ? ORDER BY measured_at DESC LIMIT 1", (c[1].measured_at,))
    row(x) = OrderedDict("commit" => String(x.commit_sha), "measured_at" => js(x.measured_at), "codecov" => js(x.codecov), "coveralls" => js(x.coveralls))
    return OrderedDict("current" => row(c[1]), "previous" => isempty(p) ? nothing : row(p[1]))
end

# Master commits newest first, for the Commit view's list: one row per
# commit in the order of its first build (a rebuild does not move it), with
# the state of its latest build and whether a daily benchmark or PkgEval
# report ran on it. `before` is the first_at of the last row already shown.
# The scheduled pipeline only rebuilt commits julia-master already had.
# Scheduled builds of julia-ci rebuild a commit under the message
# "Scheduled build", so the subject comes from another build when there is one.
function commit_list(db; before="", limit=100)
    where = isempty(before) ? "" : " WHERE c.first_at < ?"
    params = isempty(before) ? (limit,) : (before, limit)
    reports(table) = Set(first(String(r.c), 8) for r in rows(db, "SELECT DISTINCT commit_sha AS c FROM $table WHERE kind = 'daily' AND length(commit_sha) >= 8"))
    bench = reports("bench_reports")
    pkgeval = reports("pkgeval_reports")
    out = Any[]
    for r in rows(db, "WITH c AS (SELECT commit_prefix, MIN(created_at) AS first_at, MAX(id) AS last_id FROM builds " *
                      "WHERE pipeline IN ('julia-ci', 'julia-master') GROUP BY commit_prefix) " *
                      "SELECT c.commit_prefix, c.first_at, b.state, f.author, f.message FROM c JOIN builds b ON b.id = c.last_id " *
                      "JOIN builds f ON f.id = (SELECT id FROM builds x WHERE x.commit_prefix = c.commit_prefix " *
                      "ORDER BY x.message = '$SCHEDULED_MESSAGE', x.created_at LIMIT 1)" *
                      where * " ORDER BY c.first_at DESC LIMIT ?", params)
        prefix = String(r.commit_prefix)
        push!(out, OrderedDict("commit" => prefix, "first_at" => String(r.first_at), "state" => jstr(r.state),
                               "author" => String(r.author), "message" => String(r.message),
                               "benchmarks" => prefix in bench, "pkgeval" => prefix in pkgeval))
    end
    return OrderedDict("before" => before, "commits" => out)
end

function commit(db, ref)
    candidates = commit_candidates(db, ref)
    if length(candidates) != 1
        matches = [commit_summary(db, p, s) for (p, s) in Iterators.take(candidates, COMMIT_LIST_LIMIT)]
        return OrderedDict("query" => ref, "matches" => matches)
    end
    prefix, sha = only(candidates)
    info = commit_summary(db, prefix, sha)
    sha = info["sha"]
    builds = commit_builds(db, prefix, sha)
    primary = primary_build(builds)
    t = info["created_at"]
    return OrderedDict(
        "query" => ref, "commit" => info,
        "previous" => primary === nothing ? nothing : neighbour(db, primary["pipeline"], primary["build"], prefix, :prev),
        "next" => primary === nothing ? nothing : neighbour(db, primary["pipeline"], primary["build"], prefix, :next),
        "builds" => builds,
        "jobs" => primary === nothing ? nothing : commit_jobs(db, primary),
        "ttfx" => commit_ttfx(db, prefix, sha),
        "benchmarks" => commit_benchmarks(db, prefix, sha, t),
        "pkgeval" => commit_pkgeval(db, prefix, sha, t),
        "coverage" => commit_coverage(db, prefix, sha))
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
