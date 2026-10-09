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
    pipeline = "julia-ci"
    where, params = where_clause("build_created_at", since, "")
    function jobs(kind)
        out = Any[]
        sql = "SELECT * FROM ttfx_jobs" * (isempty(where) ? " WHERE" : where * " AND") * " kind = ? ORDER BY build_created_at, build"
        for j in rows(db, sql, (params..., kind))
            pipeline = String(j.pipeline)
            tasks = get(results, String(j.job_uuid), Dict{String,Any}())
            n = Int(j.n_metrics)
            push!(out, Dict{String,Any}(
                "build" => Int(j.build), "job_id" => String(j.job_uuid), "triplet" => String(j.triplet), "state" => String(j.state),
                "date" => iso_to_legacy_minute(String(j.build_created_at)), "commit" => String(j.commit_sha),
                "version" => String(j.version), "message" => String(j.message), "agent" => String(j.agent), "cpu" => String(j.cpu),
                "snippets" => String(j.snippets), "blocks" => js(j.blocks), "n_tasks" => js(j.n_tasks),
                "tasks" => Dict(k => v[1:n] for (k, v) in tasks),
                "failed" => get(failures, String(j.job_uuid), Dict{String,String}())))
        end
        return out
    end
    builds = jobs("master")
    releases = jobs("release")
    task_names = sort!(unique(String[k for b in builds for d in (b["tasks"], b["failed"]) for k in keys(d)]))
    return OrderedDict("generated_at" => generated_at(db, "ttfx"), "pipeline" => pipeline, "branch" => "master",
                       "metrics" => TTFX_METRICS, "tasks" => task_names, "builds" => builds, "releases" => releases)
end

# Open pull requests by how their latest TTFX comparison looks, best first.
# The score is the estimated head/base ratio of the suite's total time over
# precompile, load, run and warm: each metric's ratio weighted by how long it
# takes on master, so precompile counts the most. Below 1 is faster.
const TTFX_PR_METRICS = ["precompile", "load", "run", "warm"]

# A metric's ratio is the block nearest no change, and no change when the blocks
# disagree on the direction, so one noisy block moves the score neither way.
function ttfx_pr_ratio(geomeans)
    all(>(1), geomeans) && return minimum(geomeans)
    all(<(1), geomeans) && return maximum(geomeans)
    return 1.0
end

function ttfx_pr_score(suite, weights)
    total = ratio = 0.0
    for m in TTFX_PR_METRICS
        (haskey(suite, m) && !isempty(suite[m].geomeans)) || continue
        w = get(weights, m, 0.0)
        total += w
        ratio += w * ttfx_pr_ratio(suite[m].geomeans)
    end
    return total > 0 ? ratio / total : nothing
end

# Each metric's summed time over the suite in the newest master TTFX job
function ttfx_pr_weights(db)
    sql = "SELECT sum(precompile) AS precompile, sum(load) AS load, sum(run) AS run, sum(warm) AS warm FROM ttfx_results " *
          "WHERE job_uuid = (SELECT j.job_uuid FROM ttfx_jobs j WHERE j.kind = 'master' AND EXISTS (SELECT 1 FROM ttfx_results r WHERE r.job_uuid = j.job_uuid) " *
          "ORDER BY j.build_created_at DESC LIMIT 1)"
    r = only(rows(db, sql))
    return Dict(m => Float64(something(coalesce(getproperty(r, Symbol(m)), 0.0), 0.0)) for m in TTFX_PR_METRICS)
end

# Per-block product of two layers' suite geomeans, metric by metric. Layers measured with
# different block counts are combined through the ratio each one is scored by.
function ttfx_chain_suite(lower, upper)
    out = OrderedDict{String,Any}()
    for (m, u) in pairs(upper)
        haskey(lower, m) || continue
        a, b = lower[m].geomeans, u.geomeans
        (isempty(a) || isempty(b)) && continue
        g = length(a) == length(b) ? a .* b : [ttfx_pr_ratio(a) * ttfx_pr_ratio(b)]
        out[String(m)] = (geomeans=g,)
    end
    return out
end

# A pull request that targets another one's branch is measured against that branch, so
# its own suite ratios leave out everything below it. Chaining the layers down to the
# one based on master estimates the whole stack against master. The links are exact
# when each layer's base is the commit the layer below was measured at; otherwise a
# layer has moved on since and the estimate is approximate.
function ttfx_pr_stack(r, by_ref)
    base_ref = String(r.base_ref)
    (isempty(base_ref) || base_ref == "master") && return nothing
    parents, exact, child = Int[], true, r
    suite = JSON3.read(String(r.suite))
    while true
        ref = String(child.base_ref)
        (isempty(ref) || ref == "master") && break
        parent = get(by_ref, ref, nothing)
        if parent === nothing || Int(parent.pr_number) in parents || Int(parent.pr_number) == Int(r.pr_number)
            return OrderedDict("base_ref" => base_ref, "parents" => parents, "complete" => false,
                               "missing" => ref, "exact" => exact, "suite" => nothing)
        end
        push!(parents, Int(parent.pr_number))
        exact &= startswith(String(parent.head_commit), first(String(child.base_commit), 10)) && !isempty(String(child.base_commit))
        suite = ttfx_chain_suite(JSON3.read(String(parent.suite)), suite)
        child = parent
    end
    return OrderedDict("base_ref" => base_ref, "parents" => parents, "complete" => true, "missing" => nothing,
                       "exact" => exact, "suite" => suite)
end

function ttfx_prs(db)
    prs = Any[]
    weights = ttfx_pr_weights(db)
    all_rows = collect(rows(db, "SELECT * FROM ttfx_prs"))
    by_ref = Dict(String(r.head_ref) => r for r in all_rows if !isempty(String(r.head_ref)))
    for r in all_rows
        suite = JSON3.read(String(r.suite))
        own_score = ttfx_pr_score(suite, weights)
        stack = ttfx_pr_stack(r, by_ref)
        stack === nothing || (stack["score"] = stack["suite"] === nothing ? nothing : ttfx_pr_score(stack["suite"], weights))
        push!(prs, OrderedDict(
            "pr" => Int(r.pr_number), "title" => String(r.title), "author" => String(r.author), "draft" => r.draft == 1,
            # Ranked by the estimate against master: a stacked layer's own gains may only undo a regression below it
            "score" => stack === nothing ? own_score : stack["score"], "own_score" => own_score,
            "stack" => stack, "verdict" => String(r.verdict),
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
        master = table == "ttfx_jobs" ? " AND kind = 'master'" : ""
        for r in rows(db, "SELECT DISTINCT commit_sha FROM $table WHERE (commit_sha GLOB ? OR commit_sha = ?)" * master, (ref * "*", p8))
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
        t = rows(db, "SELECT message, build_created_at FROM ttfx_jobs WHERE commit_sha GLOB ? AND kind = 'master' ORDER BY build_created_at LIMIT 1", (commit_glob(prefix, sha),))
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
    tj = rows(db, "SELECT job_uuid, build, state, build_created_at, version, web_url FROM ttfx_jobs WHERE commit_sha GLOB ? AND kind = 'master' " *
                  "ORDER BY build_created_at DESC LIMIT 1", (commit_glob(prefix, sha),))
    isempty(tj) && return nothing
    j = tj[1]
    prev = rows(db, "SELECT job_uuid, build, commit_sha FROM ttfx_jobs t WHERE kind = 'master' AND build_created_at < ? AND commit_sha NOT GLOB ? AND EXISTS " *
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

# --- sizes -------------------------------------------------------------------

const SIZE_TRIPLET = "x86_64-linux-gnu"
# What sizes/summary returns unless asked for other metrics: the whole and its
# largest parts
const SIZE_SUMMARY_METRICS = ["total", "tarball", "files", "sysimg", "sysimg.text", "sysimg.image_data", "sysimg.dwarf",
                              "pkgimg.ji", "pkgimg.so", "libjulia-codegen", "libjulia-internal", "libLLVM", "libs.other",
                              "share.stdlib"]

# The CI tarballs replace the manyjulias builds from the first commit CI was
# measured on; the summary draws that switch as a marker
const SIZE_SWITCH_LABEL = "Measured from CI"
const SIZE_SWITCH_DESCRIPTION = "From here on the sizes are of the tarball each julia-ci master build uploaded. Before, they are of " *
    "manyjulias builds of the same commits, which have three CPU targets where CI has four (so the code and DWARF of sys.so and " *
    "the pkgimages are about a fifth smaller) and no share/doc or share/man: the step at this line is that difference, not a commit."

# One source's measured commits from `from` (inclusive) to `until` (exclusive)
# in merge order, with one array per metric aligned with them (null where a
# commit lacks the metric)
function size_series(db, src, wanted; from="", until="")
    window = (isempty(from) ? "" : " AND merged_at >= ?") * (isempty(until) ? "" : " AND merged_at < ?")
    params = Any[src, SIZE_TRIPLET]
    isempty(from) || push!(params, from)
    isempty(until) || push!(params, until)
    bs = rows(db, "SELECT id, commit_sha, merged_at, version, build, message FROM size_builds WHERE source = ? AND triplet = ?" * window *
                  " ORDER BY merged_at, commit_sha", params)
    index = Dict(Int(b.id) => i for (i, b) in enumerate(bs))
    values = OrderedDict(m => Vector{Any}(nothing, length(bs)) for m in wanted)
    if !isempty(bs)
        for r in rows(db, "SELECT m.size_build_id AS id, m.metric, m.value FROM size_metrics m JOIN size_builds b ON b.id = m.size_build_id " *
                          "WHERE b.source = ? AND b.triplet = ? AND m.metric IN (SELECT value FROM json_each(?))",
                      (src, SIZE_TRIPLET, JSON3.write(wanted)))
            i = get(index, Int(r.id), nothing)
            i === nothing || (values[String(r.metric)][i] = Int(r.value))
        end
    end
    return OrderedDict{String,Any}("commits" => [String(b.commit_sha) for b in bs], "merged_at" => [String(b.merged_at) for b in bs],
                                   "versions" => [String(b.version) for b in bs], "builds" => Any[js(b.build) for b in bs],
                                   "messages" => [String(b.message) for b in bs], "sources" => fill(src, length(bs)), "values" => values)
end

# The measured commits in merge order and one array per metric aligned with
# them: the manyjulias builds up to the first CI measurement and the CI
# tarballs from there, with a marker at the switch. `source` gives one source
# alone instead. `metrics` empty means the summary set, ["all"] every metric.
function sizes(db; since="", metrics=String[], source="")
    all_metrics = [String(r.metric) for r in rows(db, "SELECT DISTINCT metric FROM size_metrics ORDER BY metric")]
    wanted = isempty(metrics) ? SIZE_SUMMARY_METRICS : metrics == ["all"] ? all_metrics : metrics
    markers = Any[]
    if !isempty(source)
        series = size_series(db, source, wanted; from=since)
    else
        first_ci = rows(db, "SELECT commit_sha, merged_at FROM size_builds WHERE source = 'ci' AND triplet = ? " *
                            "ORDER BY merged_at, commit_sha LIMIT 1", (SIZE_TRIPLET,))
        switch = isempty(first_ci) ? "" : String(first_ci[1].merged_at)
        series = size_series(db, "manyjulias", wanted; from=since, until=switch)
        if !isempty(switch)
            ci = size_series(db, "ci", wanted; from=max(since, switch))
            for k in ("commits", "merged_at", "versions", "builds", "messages", "sources")
                append!(series[k], ci[k])
            end
            for m in wanted
                append!(series["values"][m], ci["values"][m])
            end
            push!(markers, OrderedDict("at" => switch, "commit" => String(first_ci[1].commit_sha),
                                       "label" => SIZE_SWITCH_LABEL, "description" => SIZE_SWITCH_DESCRIPTION))
        end
    end
    return OrderedDict("generated_at" => generated_at(db, "sizes"), "triplet" => SIZE_TRIPLET, "metrics" => all_metrics,
                       series..., "markers" => markers)
end

# Every metric of measurement `id` next to measurement `before`'s (0 for none),
# and every file of at least 1 MiB in either, the files that changed most first
function size_diff(db, id, before)
    metrics_of(i) = Dict(String(r.metric) => Int(r.value)
                         for r in rows(db, "SELECT metric, value FROM size_metrics WHERE size_build_id = ?", (i,)))
    files_of(i) = Dict(String(r.path) => Int(r.bytes)
                       for r in rows(db, "SELECT path, bytes FROM size_files WHERE size_build_id = ?", (i,)))
    metrics, metrics_before = metrics_of(id), metrics_of(before)
    files, files_before = files_of(id), files_of(before)
    paths = sort!(collect(union(keys(files), keys(files_before))),
                  by=p -> (-abs(get(files, p, 0) - get(files_before, p, 0)), p))
    return OrderedDict(
        "metrics" => OrderedDict(m => [metrics[m], get(metrics_before, m, nothing)] for m in sort!(collect(keys(metrics)))),
        "files" => [OrderedDict("path" => p, "bytes" => get(files, p, nothing), "previous" => get(files_before, p, nothing))
                    for p in paths])
end

# One commit's measurement in each source next to the previous commit that
# source measured. nothing when no source has the commit.
function size_commit(db, ref)
    occursin(r"^[0-9a-f]{7,40}$", ref) || return nothing
    out = OrderedDict{String,Any}()
    for b in rows(db, "SELECT * FROM size_builds WHERE commit_sha GLOB ? AND triplet = ? AND source != 'pr' ORDER BY source",
                  (ref * "*", SIZE_TRIPLET))
        src, sha = String(b.source), String(b.commit_sha)
        prev = rows(db, "SELECT id, commit_sha, merged_at, version FROM size_builds WHERE source = ? AND triplet = ? AND " *
                        "(merged_at < ? OR (merged_at = ? AND commit_sha < ?)) ORDER BY merged_at DESC, commit_sha DESC LIMIT 1",
                    (src, SIZE_TRIPLET, b.merged_at, b.merged_at, sha))
        out[src] = OrderedDict(
            "commit" => sha, "merged_at" => String(b.merged_at), "version" => String(b.version), "build" => js(b.build),
            "previous" => isempty(prev) ? nothing : OrderedDict("commit" => String(prev[1].commit_sha), "merged_at" => String(prev[1].merged_at),
                                                                 "version" => String(prev[1].version)),
            size_diff(db, Int(b.id), isempty(prev) ? 0 : Int(prev[1].id))...)
    end
    return isempty(out) ? nothing : OrderedDict("query" => ref, "triplet" => SIZE_TRIPLET, "sources" => out)
end

const SIZE_PR_METRICS = filter(!=("tarball"), SIZE_SUMMARY_METRICS)

const SIZE_PR_QUERY = "SELECT p.*, h.id AS head_id, h.version AS head_version, h.measured_at AS measured_at, " *
    "b.id AS base_id, b.merged_at AS base_merged_at, b.version AS base_version FROM size_prs p " *
    "JOIN size_builds h ON h.source = 'pr' AND h.triplet = ?1 AND h.commit_sha = p.head_commit " *
    "LEFT JOIN size_builds b ON b.source = 'ci' AND b.triplet = ?1 AND b.commit_sha = p.base_commit"

function size_pr_info(r)
    base = r.base_id === missing ? nothing :
        OrderedDict("commit" => String(r.base_commit), "merged_at" => String(r.base_merged_at), "version" => String(r.base_version))
    return OrderedDict("number" => Int(r.pr_number), "title" => String(r.title), "author" => String(r.author), "draft" => r.draft == 1,
                       "base_ref" => String(r.base_ref), "build" => Int(r.build), "build_created_at" => String(r.build_created_at),
                       "web_url" => js(r.web_url), "measured_at" => String(r.measured_at),
                       "head" => OrderedDict("commit" => String(r.head_commit), "version" => String(r.head_version)),
                       "merge_base" => String(r.merge_base), "base" => base)
end

# Every open pull request with a measured build, newest build first: the summary
# metrics of its head and of its merge-base, once that is measured
function size_prs(db)
    prs = rows(db, SIZE_PR_QUERY * " ORDER BY p.build DESC", (SIZE_TRIPLET,))
    ids = unique(Int[id for r in prs for id in (r.head_id, r.base_id) if id !== missing])
    values = Dict{Int,Dict{String,Int}}()
    for r in rows(db, "SELECT size_build_id AS id, metric, value FROM size_metrics WHERE size_build_id IN (SELECT value FROM json_each(?)) " *
                      "AND metric IN (SELECT value FROM json_each(?))", (JSON3.write(ids), JSON3.write(SIZE_PR_METRICS)))
        get!(values, Int(r.id), Dict{String,Int}())[String(r.metric)] = Int(r.value)
    end
    out = Any[]
    for r in prs
        e = size_pr_info(r)
        e["values"] = get(values, Int(r.head_id), Dict{String,Int}())
        e["base_values"] = r.base_id === missing ? nothing : get(values, Int(r.base_id), Dict{String,Int}())
        push!(out, e)
    end
    return OrderedDict("generated_at" => generated_at(db, "sizes"), "triplet" => SIZE_TRIPLET, "metrics" => SIZE_PR_METRICS, "prs" => out)
end

# One open pull request's measurement next to its merge-base's: every metric and
# every file of at least 1 MiB in either
function size_pr(db, number)
    n = tryparse(Int, number)
    n === nothing && return nothing
    r = rows(db, SIZE_PR_QUERY * " WHERE p.pr_number = ?2", (SIZE_TRIPLET, n))
    isempty(r) && return nothing
    e = size_pr_info(r[1])
    merge!(e, size_diff(db, Int(r[1].head_id), r[1].base_id === missing ? 0 : Int(r[1].base_id)))
    return e
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

# Buildkite states of a job that is still waiting for an agent
const QUEUED_STATES = ("scheduled", "reserved", "assigned", "accepted", "limited", "limiting")

"""
    pool_slots(db, cutoff)

Agent slots per pool (queue, os, arch) from the agents seen since `cutoff`,
the other pools each one shares its hosts with, each pool's hosts, and the most
jobs each host was seen running at once. Each host's scheduler
(JuliaCI/sandboxed-buildkite-agent) gives every agent group enough slots to
fill the host's CPUs alone, and all the groups draw on those same CPUs. A Mac,
for example, runs one build or one test at a time. So a pool gets at most as
many slots on a host as the host was ever seen running at once, and two pools
share a host when their slots there add up to more than that.
"""
function pool_slots(db, cutoff)
    names = Dict{Tuple{String,String,String},Dict{String,Int}}()
    for r in rows(db, "SELECT hostname, queue, os, arch, COUNT(*) AS n FROM agents WHERE last_seen >= ? " *
                      "GROUP BY hostname, queue, os, arch", (cutoff,))
        get!(Dict{String,Int}, names, (String(r.queue), String(r.os), String(r.arch)))[String(r.hostname)] = Int(r.n)
    end
    peak = Dict{String,Int}()
    for r in rows(db, "SELECT hostname, MAX(n) AS n FROM (SELECT m.time, a.hostname, COUNT(*) AS n " *
                      "FROM agent_snapshot_members m JOIN agents a ON a.name = m.agent_name " *
                      "WHERE m.time >= ? GROUP BY m.time, a.hostname) GROUP BY hostname", (cutoff,))
        peak[String(r.hostname)] = Int(r.n)
    end
    # A host never seen mid-job has no known limit
    cap(h, n) = min(n, get(peak, h, n))
    slots = Dict(p => sum(cap(h, n) for (h, n) in hosts) for (p, hosts) in names)
    shared = Dict{Tuple{String,String,String},Set{Tuple{String,String,String}}}()
    for (p, hp) in names, (q, hq) in names
        p < q || continue
        if any(h -> haskey(hq, h) && cap(h, hp[h]) + cap(h, hq[h]) > get(peak, h, typemax(Int)), keys(hp))
            push!(get!(Set{Tuple{String,String,String}}, shared, p), q)
            push!(get!(Set{Tuple{String,String,String}}, shared, q), p)
        end
    end
    hosts = Dict(p => sort!(collect(keys(hs))) for (p, hs) in names)
    return slots, shared, hosts, peak
end

"""
    pool_backlog(db; since="")

For each agent pool (queue, os and arch) the julia-pr and julia-ci jobs asked
for, how many were waiting for an agent and how many were running, sampled
every `step_s` seconds from `since` (all retained jobs by default) to now, with the longest wait among the waiting jobs at each
sample, the agent slots seen for the pool in the last 30 days and the pools
sharing its hosts (see `pool_slots`). The same
series per pipeline are under `by_pipeline`, so master (julia-ci) and pull
request (julia-pr) jobs can be told apart.
"""
function pool_backlog(db; since="")
    now_t = floor(now(UTC), Minute(10))
    first_r = rows(db, "SELECT MIN(runnable_at) AS t FROM pool_jobs")[1].t
    start = isempty(since) ? DateTime(0) : DateTime(since[1:min(end, 19)], length(since) <= 10 ? dateformat"yyyy-mm-dd" : dateformat"yyyy-mm-ddTHH:MM:SS")
    start = max(start, first_r === missing ? now_t - Day(7) : floor(DateTime(String(first_r), Store.ISO_SECONDS), Minute(10)))
    start = min(start, now_t)
    span = Dates.value(now_t - start) ÷ 1000
    # At most about 1000 samples, on 10-minute multiples
    step = max(600, cld(span, 1000 * 600) * 600)
    n = span ÷ step + 1
    t0 = datetime2unix(start)
    secs(x) = datetime2unix(DateTime(String(x), Store.ISO_SECONDS))
    now_s = datetime2unix(now(UTC))
    # Sample i (0-based) is at t0 + i*step; an interval [a, b) covers samples first_at(a) .. first_at(b)-1
    first_at(x) = clamp(ceil(Int, (x - t0) / step), 0, n)
    # Per pool and pipeline: changes in waiting and running per sample, and the waits
    pools = OrderedDict{Tuple{String,String,String},Dict{String,Any}}()
    acc(q, o, a, pipeline) = get!(get!(pools, (q, o, a), Dict{String,Any}()), pipeline) do
        (waiting=zeros(Int, n + 1), running=zeros(Int, n + 1), waits=Tuple{Float64,Float64}[])
    end
    for r in rows(db, "SELECT pipeline, queue, os, arch, state, runnable_at, started_at, finished_at FROM pool_jobs " *
                      "WHERE runnable_at < ? AND (finished_at IS NULL OR finished_at >= ?)",
                  (Store.iso(now_t + Minute(10)), Store.iso(start)))
        p = acc(String(r.queue), String(r.os), String(r.arch), String(r.pipeline))
        a = secs(r.runnable_at)
        # Waiting ends when the job starts, or when it is canceled before starting.
        # A job skipped with its build has neither time and never waited for an agent.
        b = r.started_at !== missing ? secs(r.started_at) :
            r.finished_at !== missing ? secs(r.finished_at) :
            String(r.state) in QUEUED_STATES ? now_s : a
        if b > a
            p.waiting[first_at(a)+1] += 1
            p.waiting[first_at(b)+1] -= 1
            push!(p.waits, (a, b))
        end
        if r.started_at !== missing
            s0 = secs(r.started_at)
            s1 = r.finished_at === missing ? now_s : secs(r.finished_at)
            p.running[first_at(s0)+1] += 1
            p.running[first_at(s1)+1] -= 1
        end
    end
    gen = agents_generated_at(db)
    slots, shared, hosts, peak = pool_slots(db, Store.iso(DateTime(gen, Store.ISO_SECONDS) - Day(30)))
    function series(p)
        # Longest wait at each sample: the earliest start among the jobs still waiting
        sort!(p.waits)
        heap = BinaryMinHeap{Tuple{Float64,Float64}}()
        oldest = zeros(Int, n)
        k = 1
        for i in 1:n
            t = t0 + (i - 1) * step
            while k <= length(p.waits) && p.waits[k][1] <= t
                push!(heap, p.waits[k])
                k += 1
            end
            while !isempty(heap) && first(heap)[2] <= t
                pop!(heap)
            end
            oldest[i] = isempty(heap) ? 0 : round(Int, t - first(heap)[1])
        end
        return OrderedDict{String,Any}("waiting" => cumsum(p.waiting)[1:n], "running" => cumsum(p.running)[1:n],
                                       "oldest_wait_s" => oldest)
    end
    out = Any[]
    for ((q, o, a), per) in pools
        by = OrderedDict{String,Any}(pl => series(per[pl]) for pl in sort!(collect(keys(per))))
        parts = collect(values(by))
        push!(out, OrderedDict{String,Any}("queue" => q, "os" => o, "arch" => a, "slots" => get(slots, (q, o, a), nothing),
                                           "hosts" => get(hosts, (q, o, a), String[]),
                                           "shared_with" => [OrderedDict("queue" => sq, "os" => so, "arch" => sa)
                                                             for (sq, so, sa) in sort!(collect(get(shared, (q, o, a), ())))],
                                           "waiting" => sum(x -> x["waiting"], parts), "running" => sum(x -> x["running"], parts),
                                           "oldest_wait_s" => reduce((x, y) -> max.(x, y), (x["oldest_wait_s"] for x in parts)),
                                           "by_pipeline" => by))
    end
    sort!(out; by=p -> -maximum(p["waiting"]; init=0))
    return OrderedDict{String,Any}("generated_at" => gen, "start" => Store.iso(start), "step_s" => step, "n" => n,
                                   "host_slots" => OrderedDict(h => peak[h] for h in sort!(unique(h for p in out for h in p["hosts"])) if haskey(peak, h)),
                                   "pipelines" => ["julia-pr", "julia-ci"], "pools" => out)
end

"""
    worker_time(db; days=7)

Agent time of the julia-pr and julia-ci jobs that finished in the `days`
before the latest agents snapshot, from start to finish, summed per pipeline,
job name, pool (queue, os and arch) and final state. Jobs still running are
left out, so every job counted ran to its end.
"""
function worker_time(db; days=7)
    gen = agents_generated_at(db)
    stop = DateTime(gen, Store.ISO_SECONDS)
    start = Store.iso(stop - Day(days))
    out = Any[]
    for r in rows(db, "SELECT pipeline, name, queue, os, arch, state, COUNT(*) AS n, " *
                      "SUM(strftime('%s', finished_at) - strftime('%s', started_at)) AS s FROM pool_jobs " *
                      "WHERE started_at IS NOT NULL AND finished_at >= ? AND finished_at < ? " *
                      "GROUP BY pipeline, name, queue, os, arch, state ORDER BY s DESC",
                  (start, gen))
        push!(out, OrderedDict{String,Any}("pipeline" => r.pipeline, "name" => r.name, "queue" => r.queue,
                                           "os" => r.os, "arch" => r.arch, "state" => r.state,
                                           "jobs" => r.n, "seconds" => max(0, r.s)))
    end
    return OrderedDict{String,Any}("generated_at" => gen, "start" => start, "end" => gen, "days" => days, "rows" => out)
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
    "sizes" => "SELECT MAX(merged_at) AS t FROM size_builds WHERE source IN ('ci', 'pr')",
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
