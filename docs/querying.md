# Querying the data

Everything perf.julialang.org shows comes from one SQLite database (`db/schema.sql` is
the authoritative description of every table). There are three ways to read it, all
public and read-only. Pick by the size of the answer:

| Need | Use |
|---|---|
| What one page of the site shows, or one commit, package or task | the API, `https://perf.julialang.org/api/` |
| A few rows or an aggregate | Datasette SQL, `https://perf.julialang.org/db/` (2 s and 5000 rows per query) |
| Many queries, or scans of the large tables | the snapshot, `https://perf.julialang.org/data/ci-timing.sqlite.gz` |

Set `B=https://perf.julialang.org` for the examples below.

## The API

`curl -s --compressed $B/api/` lists every route with its parameters. Pass `since`
(`YYYY-MM-DD`) wherever a route takes it: without it the route returns all history.
The shapes are the site's own and can change.

```sh
curl -s --compressed "$B/api/commit/95cbf209"            # one commit across every source
curl -s --compressed "$B/api/timing/builds?since=2026-09-01"
curl -s --compressed "$B/api/pkgeval/package/DataFrames"
```

## Datasette

Use `curl -s -G` with `--data-urlencode` so the SQL needs no escaping, and
`_shape=array` for a plain JSON array of rows:

```sh
curl -s -G "$B/db/ci-timing.json" --data-urlencode "_shape=array" --data-urlencode "sql=
SELECT date(b.created_at) AS day, round(avg(j.duration_s) / 60, 1) AS mean_min, count(*) AS runs
FROM jobs j JOIN builds b ON b.id = j.build_id
WHERE j.name = ':linux: test x86_64-linux-gnu' AND b.pipeline = 'julia-ci'
  AND b.created_at >= date('now', '-7 days')
GROUP BY day ORDER BY day"
```

Aggregate in SQL; do not page through raw rows, that is what the snapshot is for. Table
and column descriptions are in `$B/db/-/metadata.json`, and the saved queries listed
under `queries` in `$B/db/ci-timing.json` run as
`$B/db/ci-timing/<name>.json?_shape=array&<parameter>=<value>`.

## The snapshot

```sh
curl -O $B/data/ci-timing.sqlite.gz && gunzip ci-timing.sqlite.gz   # about 220 MB, 700 MB unpacked
sqlite3 ci-timing.sqlite
```

It is taken after every ingest. No row or time limits, and no load on the host.

## Tables by topic

- **CI timing.** `builds` (one per Buildkite build: pipeline, number, commit_prefix,
  commit_sha, state, author, message, created_at, started_at, finished_at) and `jobs` (one
  per job attempt: build_id, name, retry, state, duration_s, runnable_at, started_at,
  agent_hostname). Pipelines: `julia-ci` (current), `julia-master` and
  `julia-master-scheduled` (stopped in July 2026). `coverage` holds Codecov and Coveralls
  percentages per commit.
- **Benchmarks.** `bench_reports` (one per Nanosoldier report; `kind = 'daily'` for the
  regular ones), `bench_names` (grp, name), `bench_results` (report, benchmark and estimate:
  time_ns, gctime_ns, memory_bytes, allocs), `bench_verdicts` (Nanosoldier's comparison
  with the baseline: verdict, time_ratio, memory_ratio), `bench_report_groups` (group
  geometric means).
- **PkgEval.** `pkgeval_reports` (one per run, with outcome counts), `packages` (names),
  `pkgeval_results` (report and package: status, reason, version, duration_s),
  `pkgeval_reasons` (counts per status and reason).
- **TTFX.** `ttfx_jobs` (one per master build's TTFX job), `ttfx_results` (job and task:
  precompile, load, run, warm, and load, run and warm with the GC off, in seconds),
  `ttfx_failures`, `ttfx_samples` (every repeat).
- **Downloads.** `dl_series` (requests per day), `dl_mix` (by Julia version and release
  stage), `dl_packages` (per package, day and client type), `dl_package_uuids` and
  `registry_packages` (uuid to name), `julia_tags`.
- **Agents.** `agents` (every Buildkite agent seen), `agent_snapshots` and
  `agent_snapshot_members` (who was connected at each ingest).
- **Freshness.** `source_runs`: when each fetcher ran and whether it succeeded.

## Example queries

Slowest jobs of the latest julia-ci build:

```sql
SELECT j.name, round(j.duration_s / 60, 1) AS min, j.state, j.agent_hostname
FROM jobs j JOIN builds b ON b.id = j.build_id
WHERE b.pipeline = 'julia-ci' AND b.number = (SELECT max(number) FROM builds WHERE pipeline = 'julia-ci')
ORDER BY j.duration_s DESC LIMIT 15
```

Queue wait per build over two weeks (runnable to started):

```sql
SELECT b.number, b.commit_prefix, count(*) AS jobs,
       round(avg((julianday(j.started_at) - julianday(j.runnable_at)) * 86400)) AS mean_wait_s,
       round(max((julianday(j.started_at) - julianday(j.runnable_at)) * 86400)) AS max_wait_s
FROM jobs j JOIN builds b ON b.id = j.build_id
WHERE b.pipeline = 'julia-ci' AND j.runnable_at IS NOT NULL AND b.created_at >= date('now', '-14 days')
GROUP BY b.id ORDER BY b.number DESC
```

Nanosoldier's regressions in the latest daily report:

```sql
SELECT n.grp, n.name, round(v.time_ratio, 2) AS time_ratio, round(v.memory_ratio, 2) AS memory_ratio
FROM bench_verdicts v JOIN bench_names n ON n.id = v.bench_id
WHERE v.verdict = 'regression'
  AND v.report_id = (SELECT id FROM bench_reports WHERE kind = 'daily' ORDER BY date DESC LIMIT 1)
ORDER BY v.time_ratio DESC LIMIT 30
```

One benchmark's minimum time over 60 days. Benchmark names are the strings
BaseBenchmarks writes; find one with
`SELECT name FROM bench_names WHERE grp = 'array' AND name LIKE '%sumelt%'`.

```sql
SELECT r.date, r.commit_sha, res.time_ns, res.memory_bytes, res.allocs
FROM bench_results res JOIN bench_names n ON n.id = res.bench_id JOIN bench_reports r ON r.id = res.report_id
WHERE n.grp = 'array' AND n.name = 'index/(''sumelt'', ''1.0:1.0:100000.0'')' AND res.stat = 'minimum'
  AND r.date >= date('now', '-60 days')
ORDER BY r.date
```

A package's PkgEval history:

```sql
SELECT r.date, p.status, p.reason, p.version, r.julia_version
FROM pkgeval_results p JOIN packages k ON k.id = p.package_id JOIN pkgeval_reports r ON r.id = p.report_id
WHERE k.name = 'DataFrames' ORDER BY r.date DESC LIMIT 20
```

TTFX of one task per build over 30 days:

```sql
SELECT j.build, j.commit_sha, j.build_created_at, r.precompile, r.load, r.run, r.load_gcoff, r.run_gcoff
FROM ttfx_results r JOIN ttfx_jobs j ON j.job_uuid = r.job_uuid
WHERE r.task = 'BaseDirs/Project-Path' AND j.build_created_at >= date('now', '-30 days')
ORDER BY j.build_created_at
```

One package's downloads per day, user and CI:

```sql
SELECT d.date, sum(CASE WHEN d.client_type = 'user' THEN d.request_count ELSE 0 END) AS user,
       sum(CASE WHEN d.client_type = 'ci' THEN d.request_count ELSE 0 END) AS ci
FROM dl_packages d JOIN dl_package_uuids u ON u.id = d.package_id JOIN registry_packages g ON g.uuid = u.uuid
WHERE g.name = 'DataFrames' GROUP BY d.date ORDER BY d.date
```

## Things to know

- Times are UTC ISO 8601 (`...Z`). Durations are seconds, benchmark times nanoseconds,
  memory bytes. The API's timing run rows use the older `yyyy-mm-dd HH:MM` form.
- Many older builds have only `commit_prefix` (8 characters); `commit_sha` is filled for
  builds fetched from the Buildkite API.
- Queue waits and build wall times exist only for builds since September 2026.
- Per-package PkgEval results exist for reports since 2025-09. The `packages` table also
  holds about 2.9k uuid-shaped names from 2019-20 reports; ignore them.
- `dl_packages.request_addrs` counts distinct addresses within one row only; never sum it.
- Data is refreshed every hour; `$B/healthz` says when each source last ran.
- To share a result, link the site with the view in its URL: `$B/commit?c=<sha>`,
  `$B/pkgeval?pkg=DataFrames`, `$B/downloads?edpkg=DataFrames`, `$B/builds?t=30`,
  `$B/history?bt=90&bm=memory&bv=verdicts`.
