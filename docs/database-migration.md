# Plan: move julia-ci-timing to a database on AWS (#13)

Drafted 2026-09-21. Reviewed twice by Codex (gpt-6-astra); the accepted findings
are folded in below and in `db/schema.sql`.

Status (2026-09-21, night): stages 0, 1 and 3 are done and the branch is
ready to merge as the stage 2 cutover, short of DNS. The host at
http://3.82.159.74 (`infra/terraform`, applied as the `ci-timing` profile in
the julia-perf-website-prod account) runs the fetchers every two hours, the
API (`db/serve.jl` at `/api/`, which the site reads exclusively), Datasette at
`/db/`, the extracts at `/data/*` with the database snapshot, and `/healthz`;
`.github/workflows/deploy.yml` builds and deploys on push, `health.yml`
checks freshness, disk and backup age daily. The benchmark history was
re-parsed on the host (`fetch_benchmarks.jl --backfill-stats`: every
statistic, memory, allocations, Nanosoldier's verdicts) and the last year of
PkgEval reports fetched again (`fetch_pkgeval.jl --backfill-packages 365`).
The committed `data/` is gone except the two hand-maintained files: main's
last copy is archived at `s3://ci-timing-393686272827-us-east-1-backups/legacy/`
(and in the git history until the squash). The GitHub Pages site stays as
its last deployment, frozen, until perf.julialang.org points at the host;
its update workflow, the fetch-and-commit job and the stage 1 gate are
deleted. Left: the DNS change and HTTPS (`site_hostname`, a Caddyfile
change that replaces the instance), then turning Pages off.

## Where we are

- Static site (`index.html` + `assets/app.js`) on GitHub Pages at perf.julialang.org,
  reading 27 MB of gzipped JSON from `data/`.
- Six Julia fetchers run on a 2-hour Actions cron and commit the results. The 11 MB
  timing gzip is rewritten nearly every run and git can't delta it: history was
  squashed on 2026-09-19 and the repo is 158 MB again after 7 data commits.
- The browser downloads the 56 MB (raw) timing file to show a 30-day default view;
  refreshes every 5 minutes are ETag-revalidated, so they only cost when data
  changed (every 2 h).
- Data: ~250k timing rows, ~2.2M benchmark cells, a few thousand rows elsewhere.
- `fetch_timing.jl:240-245` refuses to rebuild from scratch (Buildkite retains a
  window): the committed timing file is the only copy of ~2 years of history and
  must be imported.
- `fetch_packages.jl` rebuilds from upstream's rolling ~296-day window, so download
  history is silently lost today. A database keeps it.
- `compare_build.jl`, `ci-timing-check.yml` and the `?c=` comparison mode are
  superseded by the TTFX CI job and get deleted.

## Shape: copy julia-perf

JuliaCI/julia-perf runs in the same account with the pattern we need
(`infra/terraform/`): one EC2 instance in us-east-1, Elastic IP, Caddy for TLS,
images from ECR, SQLite on the root volume, S3 backups with restore-on-boot, SSM
only, read-only Datasette at `/db/`.

**SQLite, not RDS.** Single writer, small data, one-file backups, no VPC/NAT/RDS
cost, Datasette gives a public JSON+SQL API for free. Plain SQL schema, so Postgres
later is mechanical. Cost: one host is one outage domain; acceptable for a
dashboard, and Pages stays up as a fallback through the rollback window.

**On the box:**
- `caddy`: static site, `/data/` extracts, proxies `/db/`. Must serve `.json.gz`
  as raw bytes (no `Content-Encoding: gzip`), since `app.js:48` decompresses
  explicitly.
- `datasette`: mutable mode, WAL, `sql_time_limit_ms` and `max_returned_rows`
  bounded.
- `ingest`: Julia fetchers under a systemd timer every 2 h, flock'd; writes SQLite,
  then renders today's `data/*` files via temp-file + rename into Caddy's
  directory. A failing source leaves its previous extract in place, matching
  today's `if: always()`.

Single origin, so the front end's relative `data/...` URLs don't change. No Julia
HTTP server in v1.

**Not doing:** RDS, EFS, Lambda, CloudFront, DynamoDB.

## Schema sketch

`db/schema.sql` is the source of truth; this sketch is the rationale. Where the
two differ the schema won: benchmark times are REAL (the legacy data is
Float64), `jobs` carries `duration_s` and a nullable `job_uuid` because
imported rows have neither timestamps nor UUIDs, `bench_results` has one row
per statistic, `bench_reports`/`pkgeval_reports` are keyed by path so PR
reports can share a day, the download tables have composite keys over every
rollup dimension, `dl_series`/`dl_mix`/`ttfx_results` are materialized because
legacy history cannot be re-derived, and `change_seq` (a monotonic counter
advanced only on content change) replaces `updated_at` as the incremental
cursor.

Full SHAs, second-precision UTC instants, one row per fact. Legacy exports
truncate to today's formats.

```sql
commits       (sha PK, author, author_date, commit_date, subject, pr_number)     -- hub every source joins to

builds        (id, pipeline, number, commit_sha, branch, state, source, author, message,
               created_at, scheduled_at, started_at, finished_at, web_url, updated_at, UNIQUE(pipeline, number))
jobs          (id, build_id, job_uuid UNIQUE, name, step_key, kind_id, agent_name, agent_hostname, queue,
               state, exit_status, soft_failed, retried, retries_count, retry_type,
               created_at, scheduled_at, runnable_at, started_at, finished_at, web_url, updated_at)
job_kinds     (id, name, kind, os, triplet, flags)     -- build/test/coverage/docs/upload/pipeline/special; assert, rr, gcoff, ...
raw_builds    (pipeline, number, fetched_at, json_zst, PK(pipeline, number))     -- Buildkite retains only a window
coverage      (commit_sha PK, date, codecov, coveralls, updated_at)

bench_reports (id, date UNIQUE, date_path, commit_sha, baseline_commit_sha, baseline_date,
               julia_version, llvm, cpu, os, benchmarktools_version, nanosoldier_commit,
               report_total, report_regressions, report_improvements)
bench_names   (id, grp, name, UNIQUE(grp, name))
bench_results (report_id, bench_id, min_ns, median_ns, mean_ns, std_ns, gctime_ns, memory_bytes, allocs,
               time_tolerance, memory_tolerance, verdict, time_ratio, memory_ratio, PK(report_id, bench_id))
bench_errors  (report_id, bench_id, error)
bench_group_stats (report_id, grp, stat, geomean_ns, count, PK(report_id, grp, stat))  -- presence per (report, group, stat)

pkgeval_reports (id, date UNIQUE, date_path, commit_sha, julia_version, total, ok, fail, crash, skip, kill)
pkgeval_reasons (report_id, status, reason, count, PK(report_id, status, reason))
pkgeval_results (report_id, package, version, status, reason, duration_s, PK(report_id, package))

ttfx_jobs     (job_uuid PK, build, triplet, state, date, commit_sha, version, message, agent, cpu, snippets,
               blocks, n_tasks, n_metrics, started_at, finished_at)
ttfx_samples  (job_uuid, task, arm, block, status, error, precompile_s, load_s JSON, run_s JSON, total_s JSON,
               load_gcoff_s JSON, run_gcoff_s JSON, total_gcoff_s JSON, PK(job_uuid, task, arm, block))
ttfx_results  (job_uuid, task, precompile, load, run, warm, load_gcoff, run_gcoff, warm_gcoff, PK(job_uuid, task))  -- derived
ttfx_failures (job_uuid, task, error)
raw_ttfx      (job_uuid PK, fetched_at, results_zst, meta_zst)      -- artifacts expire on Buildkite

dl_resource_types (date, resource_type, status, client_type, request_addrs, request_count, cache_misses, body_bytes_sent, request_time_s)
dl_julia_versions (date, julia_version, client_type, request_addrs, request_count, successes, cache_misses, body_bytes_sent, request_time_s)
dl_julia_systems  (date, julia_system, client_type, ...)
dl_client_types   (date, client_type, ...)
dl_packages       (date, package_uuid, status, client_type, request_addrs, request_count, cache_misses, body_bytes_sent)
julia_tags    (tag PK, date, published_at, url, prerelease)

agent_snapshots (time PK) + agent_snapshot_members (time, agent_name, job_uuid)
agents        (name PK, agent_id, hostname, ip_address, queue, os, arch, version, meta_data JSON, state,
               connected_at, first_seen, last_seen, job_json)
hosts         (hostname PK, group, queue, first_seen, last_seen)   -- derived from agent names

source_runs   (source, started_at, finished_at, ok, rows_written, error)   -- freshness + alerting
-- hand-maintained, stay in git, loaded on each ingest: ttfx_annotations, methodology_changes
```

`updated_at` is the modification cursor for incremental clients. `n_metrics`
preserves TTFX's "short row, re-fetch" rule (`fetch_ttfx.jl:284-304`).
`bench_group_stats` makes benchmark backfill a query: reports x groups x stats
lacking a row. Derived tables (`ttfx_results`, group geomeans, download series)
are recomputed from the fact tables at export time, so a definition change
never needs a re-fetch.

Merge rules, unchanged from the fetchers:
- timing: upsert by `(pipeline, build, name, retry)` within the ~50-build
  lookback, never delete
- coverage: fill null fields only
- benchmarks: insert new dates, never overwrite detail cells
- pkgeval: insert-only
- TTFX: replace a job and its children in one transaction
- packages: upsert by date, keep history
- agents: overwrite all fields except `first_seen`, mark absentees disconnected
  with `job = null`, expire after 12 months in the export rather than by deletion

## What else to store, and why

The fetchers were written to produce one chart each, so they drop most of what
the sources give. Verified against live payloads on 2026-09-21. Sizes are for
SQLite on the box.

### Timing (Buildkite builds API)

Kept today per job: hostname, duration, state. Dropped, and worth keeping:

- **Queue wait**: `runnable_at` to `started_at`. The most-asked CI question is
  "slow because of capacity or because of the code", and today it cannot be
  answered. Store all five job timestamps (`created_at`, `scheduled_at`,
  `runnable_at`, `started_at`, `finished_at`) at second precision; today the
  build's `created_at` is truncated to the minute and used for every job.
- **Build wall time**: build `started_at`/`finished_at`, `state`, `blocked`,
  `source` (webhook vs schedule vs api). "How long does master CI take end to
  end" becomes a headline metric.
- **Retries and flakiness**: pass `include_retried_jobs=true` and keep
  `retried`, `retries_count`, `retry_type`, `exit_status`, `soft_failed`.
  `retry` is 0 on every record today and the retry-aware UI (`app.js:722,1794`)
  is dormant because the listing only returns the final attempt.
- **Identity**: job `id` and `web_url` (link to the log), `step_key` (stable
  grouping; names carry emoji and drift), `parallel_group_index`.
- **Agent name** (`<group>-<host>.<slot>`) and `queue`, next to the hostname.
- **Full 40-char commit and branch.** Coverage is keyed by full SHA today and
  timing by an 8-char prefix, so they only join by prefix match.
- **Raw build JSON**, zstd-compressed, a few KB per build: Buildkite only keeps
  a window, and `fetch_timing.jl:240` refusing to rebuild exists because of that.

PR builds stay out of scope, but `branch` and `pull_request` columns cost
nothing and leave the door open.

### Benchmarks (NanosoldierReports)

`data.tar.zst` holds `minimum`, `median`, `mean` and `std` estimates, each with
`time`, `gctime`, `memory` and `allocs`, plus per-benchmark tolerances and an
`errors.json`. We keep `minimum.time` and `mean.time`.

- **`memory` and `allocs`** are integers and nearly noise-free, so allocation
  regressions are far easier to catch than time regressions. Store them.
- **`median`** is the robust statistic BenchmarkTools recommends; `std` gives
  the noise floor the AGENTS.md scripts currently estimate from history.
- **Nanosoldier's own verdict** per benchmark (the report table's time and
  memory ratios and :x:/:white_check_mark: flags) and the **baseline commit**
  from the `Comparison Range` line, not just the baseline date.
- **Report environment**: Julia version, LLVM, CPU model, OS, BenchmarkTools and
  Nanosoldier versions from `## Version Info`. Half of
  `methodology_changes.json` (runner or LLVM changes) becomes derivable.
- Size: ~4.8k benchmarks x 440 reports x 10 columns is ~2.1M rows, ~200 MB.
- Later: `benchmark/by_hash/` in the same repo holds the PR-triggered
  `@nanosoldier runbenchmarks` reports; same schema, `pr_number` set.

### PkgEval (NanosoldierReports)

`db.json` has 12.4k packages per day with `status`, `reason` (`precompile`,
`test_errors`, `time_limit`, `uninstallable`, ...), `version` and `duration`.
We keep six counts.

- **Per-package rows** answer "when did my package start failing and why",
  which is what package authors and compiler devs actually ask.
- **Counts by reason** per day even where per-package history is thinned.
- Size: 12.4k/day is ~4.5M rows/year (~150 MB). Full backfill is ~20M rows;
  import the last 12 months in full and status transitions only before that,
  then decide once measured.
- Later: `pkgeval/by_hash/` for PR runs, like benchmarks.

### TTFX (Buildkite artifacts)

`results.json` has one record per task per ABBA block with `precompile_time`
and the `load_times`/`run_times`/`total_times` arrays (plus `_gcoff`), and
`results-meta.json` has settings, system and snippets. We keep the minimum
over blocks of seven derived numbers.

- **Store the per-block samples**; derive min, median and spread at export.
  The definition of `warm` (best of the later runs) can then change without a
  re-fetch, which matters because the artifacts expire on Buildkite. Keep the
  raw artifact pair compressed for the same reason.
- Job `started_at`/`finished_at` and agent name, as for timing.

### Package downloads (julialang-logs S3 rollups)

The two CSVs we read have `request_addrs` (distinct client addresses, the
closest thing to "users"), `cache_misses`, `body_bytes_sent`, `request_time`
and full patch-level Julia versions; we reduce them to three totals a day.
The same prefix also publishes `package_requests_by_date`,
`julia_systems_by_date`, `client_types_by_date` and `*_by_region_by_date`
(all verified present).

- **Store the rollup rows as-is**, keyed by date, and compute the site's series
  as views. History then accumulates instead of falling off upstream's ~296-day
  window, and new charts (OS/arch mix, bytes served, distinct addresses,
  patch-level adoption of a release) need no re-fetch.
- **`package_requests_by_date`** is the big one: ~79k rows/day
  (package x status x client type), and upstream keeps only 3 days. Nobody
  else has this history. Filter to successful package requests (~20k rows/day,
  ~7M rows/year, ~300 MB) and per-package download charts become possible.

### Agents (Buildkite agents API)

Add `id`, `ip_address`, `creator`, the full `meta_data` tag list (queue, os,
arch and the custom capability tags), and the current job's `id`/`web_url`.
Derive a `hosts` table from the `<group>-<host>.<slot>` naming so the folding
now done in `app.js` happens once at ingest. Two-hourly snapshots stay; per-job
agent utilization comes from `jobs` anyway.

### Commits hub

A `commits` table from a bare clone of JuliaLang/julia on the box
(`git log --format` is free): full SHA, author, author and commit dates,
subject, PR number. Every source keys on it, so any point on any chart links
to its PR, the 8-char prefixes in legacy data resolve once at import, and all
sources share a time axis (commit date) instead of "when Nanosoldier happened
to run".

### Datetimes and units

Today's formats are mixed: timing and TTFX `"yyyy-mm-dd HH:MM"` (minute
precision, UTC implied, custom parser in `app.js`), `generated_at` and agents
ISO 8601 `Z`, benchmarks and PkgEval `YYYY-MM-DD` plus a `YYYY-MM/DD`
`date_path`, coverage ISO from two providers.

Rules for the database:
- Instants are ISO 8601 UTC with seconds and a `Z`, in TEXT columns
  (`2026-09-20T13:51:01Z`). SQLite has no datetime type; ISO text sorts
  correctly, works with `date()`/`strftime()`, and reads well in Datasette.
  Never truncate at ingest; the legacy export truncates.
- Days are `YYYY-MM-DD` only where the source is a day (Nanosoldier report
  date, PkgEval date, download rollups). `date_path` is derived.
- Column names say the type: `*_at` instants, `date` days, `*_s` seconds,
  `*_ns` nanoseconds, `*_bytes`. Durations are REAL seconds except benchmark
  times, which stay integer nanoseconds.
- Every row carries `updated_at` (set on upsert); `source_runs` carries the
  per-source freshness.
- The API returns ISO strings; `Date.parse` handles them, and the custom
  minute-precision parser goes away in stage 3.

### Organization

- Facts in, derivations out: store what the source said, compute geomeans,
  minimums and series at export or in views.
- Classification at ingest: `job_kinds` replaces `classifyJob` (`app.js:2728`),
  `hosts` replaces the agent-name folding, `commits` replaces prefix matching.
- Upstream IDs and URLs on every row (job `web_url`, report `date_path`,
  PkgEval log path) so the UI can link out.
- Raw payloads kept only where upstream forgets (Buildkite builds, TTFX
  artifacts); NanosoldierReports and the S3 rollups are their own archive.

## Stages

### Stage 0: DB-backed pipeline in this repo (~1 week, no AWS)

- Delete the comparison feature: `compare_build.jl`, `ci-timing-check.yml`, README
  section, `.julia-repo-cache` in `.gitignore`/AGENTS.md, and
  `parseComparisonParam`/`applyComparisonParam`/`updateComparisonBanner`/
  `clearComparison` plus the `comparisonData` branches in `app.js` (the `c` key at
  `app.js:2018` is the coverage toggle, keep it).
- `db/schema.sql`, `db/Store.jl` (SQLite.jl, WAL, upserts, `updated_at`).
- `db/import_legacy.jl`: build the DB from the current `data/` files (the history
  backfill).
- Each `fetch_*.jl` reads "known" state from the DB and upserts, and captures the
  extra columns from "What else to store" (same endpoints, more fields; the only
  new requests are `include_retried_jobs=true`, the extra download CSVs and the
  bare julia clone). Lookbacks unchanged. Refuse to run against an empty DB
  unless `--bootstrap` is passed.
- `db/export.jl`: renders every current file (`data/*.json.gz`,
  `data/benchmarks/*.json.gz`, `data/agents/*`), atomic writes.
- `analysis/fetch_data.jl`: downloads the extracts into a gitignored `data/` so
  `BenchHistory.jl` and `tools/inspect-bench.mjs` keep working after stage 2.
- Gate (exact): import -> export reproduces the committed files under the
  fetchers' own structural comparison. Then run the DB-backed fetchers locally for
  a few cycles alongside the Actions commits.

### Stage 1: duplicate site on AWS (~1 week, then 2+ weeks soak)

- `infra/terraform/` from julia-perf, `name_prefix = "ci-timing"`, own instance
  (t4g.medium arm64 or julia-perf's t3a.medium; 4 GB for the benchmark parse).
- Secrets: `BUILDKITE_API_TOKEN` (and an optional fine-grained GitHub token for
  the releases API; unauthenticated is enough at 2 calls per 2 h) in SSM Parameter
  Store, read by the instance role at ingest time.
- Seed: upload the stage 0 SQLite file to the S3 backup path; first boot restores
  it. Restore runs only onto an empty data volume.
- Backups: SQLite online `.backup` to S3 after every ingest run (latest) plus the
  daily archive with 30-day retention that julia-perf's timer already provides;
  pre-deploy backup; a documented and once-rehearsed restore.
- Deploy: Actions on push to `main` builds the image (immutable, digest-pinned),
  pushes to ECR, `aws ssm send-command` pulls and restarts. The DB isn't touched.
  Instance replacement kept for base-image changes.
- Monitoring: `/healthz` reports each source's last successful run from
  `source_runs` and the disk in use; the daily gate below fails if any
  source's file is >6 h stale, the disk is >80% full, or the latest backup in
  S3 is >1 day old. Needed because `fetch_agents.jl:77-80` exits 0 on 401/403.
- Hostname: e.g. next.perf.julialang.org, A record to the EIP. Needs the
  julialang.org DNS owner.
- Gate: `db/compare_origins.jl`, run daily by `compare-origins.yml`, compares
  the two origins' `data/` by key: settled timing runs (builds below the
  fetcher's fully-captured threshold), benchmark, pkgeval, TTFX, coverage and
  download rows dated before 48 h ago, agents by freshness only. The host must
  have every settled row of Pages unchanged; extras (history the files
  dropped, reports the old fetchers skipped) are counted, not failed.

### Stage 2: cutover (a day, plus DNS lead time)

- Archive the final `data/` as a release asset on this repo (27 MB) and in the
  backup bucket.
- Point perf.julialang.org at the EIP (lower the TTL first; today it's a CNAME to
  Pages). Caddy issues the cert.
- Remove the fetch-and-commit job from `update-timing.yml`. Keep `data/`
  committed and Pages deploying at juliaci.github.io/julia-ci-timing as a frozen,
  independent fallback for a defined window (say 4 weeks).
- After the window: delete `data/` except the two hand-maintained files, final
  squash, turn Pages off or leave it as a redirect.

### Raw access for people and agents

The site's own files are not the only way out of the database:

- **Datasette at `/db/`** (stage 1): public, read-only SQL over HTTP with
  JSON and CSV output, the same thing julia-perf exposes. `curl
  "https://perf.julialang.org/db/ci-timing.json?sql=SELECT+..."` is enough
  for a script or an agent; the schema is browsable there too. Bounded by
  `sql_time_limit_ms` and `max_returned_rows` (raise the row limit for canned
  queries that need it).
- **`/data/*.json.gz`**: the extracts keep being published, so anything that
  reads them today (the `analysis/` scripts, the TTFX skill) keeps working
  with a URL instead of a checkout.
- **A daily database snapshot** at `/data/ci-timing.sqlite.zst` (the
  online-backup copy, compressed): one download and any agent can run
  arbitrary SQL locally with `sqlite3`, with no load on the host and no row
  limits. About 50 MB today.

AGENTS.md gets a section pointing at all three once stage 1 is up.

### Protecting julia-perf's database

Nothing here touches julia-perf (JuliaCI/julia-perf, the Benchmarks tab's
backend): it keeps its own instance, `julia.db`, backup bucket and
Datasette, and this deployment has its own Terraform state and
`name_prefix`. The account is `julia-perf-website-prod` (393686272827), reached through
IAM Identity Center (`aws sso login --sso-session julialang`, the 1Password
item "IanButterworth - JuliaLang AWS"). Guards applied on 2026-09-21:

1. **Scoped credentials.** IAM role `ci-timing-deployer` (PowerUserAccess,
   plus `ci-timing-deployer-iam` for IAM on `ci-timing-*` names only, plus
   `ci-timing-deny-rustc-perf`: an explicit `Deny` on everything tagged
   `Project=rustc-perf` and on each julia-perf resource by id: the bucket,
   ECR repository, IAM role/profile/policy names, instance, volume, snapshot,
   EIP, VPC, subnet, security groups, IGW, route tables, plus SSM/Instance
   Connect to the instance). Every Terraform and CLI action for this project
   runs as the `ci-timing` AWS profile, which assumes that role; the SSO
   PowerUser/Admin profiles are only for account-level chores. Verified:
   reads, writes, IAM and SSM against julia-perf all fail with the deny named.
2. **S3 versioning** on `rustc-perf-393686272827-us-east-1-backups`, with a
   lifecycle rule `expire-noncurrent-versions` (noncurrent versions expire
   after 7 days, expired delete markers cleaned) so the daily 834 MB overwrite
   of `latest.tar.gz` does not accumulate forever (about 12 GB extra, under
   $0.30/month). The lifecycle configuration is managed by julia-perf's
   Terraform (`aws_s3_bucket_lifecycle_configuration.backups`), so a
   `terraform apply` there would drop the added rule while versioning stays
   on; the rule (and an `aws_s3_bucket_versioning` resource) should be added
   to julia-perf's `main.tf` to make it permanent.
3. **EBS snapshot** `snap-0dd4dc81dca859105` of the root volume
   `vol-0b02abeabbc3272f8`, tagged `Purpose=manual-restore-point`, taken
   before any other change in the account.
4. Still julia-perf's call: `prevent_destroy` on the bucket and
   `disable_api_termination` on the instance, which needs `deploy.sh` to lift
   it before an instance replacement.

A separate AWS account for perf.julialang.org would make 1 structural
rather than policy-based; it needs the organization admin and can be done
later without changing anything here.

### Stage 3: use the database (incremental, tab by tab)

Done (2026-09-21) with an HTTP.jl server rather than Datasette canned queries:
the benchmark detail alone is 1.2M cells for the `scalar` group, which
Datasette cannot shape or return in time, and every tab wants the shapes the
files already had.

- `db/Render.jl` builds those shapes from the database (with a window where
  the data is large); `db/export.jl` writes them to `data/` and `db/serve.jl`
  serves them at `/api/` (routes in its header). Responses carry an ETag from
  the change sequence and are cached gzipped per (request, sequence).
- Timing: `/api/timing/runs?since=` for the shown range (30 days is ~12k
  rows, 0.2 MB gzipped with the build's commit, author, message and date
  sent once per build, against 11 MB for the file); the range widening
  fetches the older runs and merges them by (pipeline, build, job, retry);
  refresh asks for `changed_since=<change_seq>` and upserts. Benchmarks:
  the summary plus per-group detail windowed on the report date, reloaded
  when the range widens. The other tabs read their summary in one request.
- The browser probes `api/status` once: without it (the Pages copy, a
  static checkout) every loader reads the files as before.
- The views the database made possible: a CI → Builds tab (wall time, queue
  wait and job time per master build, `/api/timing/builds`; the Commits tab
  was folded into it); on Benchmarks a metric selector (time, GC time,
  memory, allocations: `?metric=` on the summary and group routes, with the
  geomeans materialized in `bench_report_groups` by the fetcher) and a
  Verdicts table (Nanosoldier's own regressions and improvements with time
  and memory ratios, `/api/benchmarks/verdicts`); on PkgEval a package box
  (status history per report, `/api/pkgeval/package/<name>`) and the failure
  reasons of the latest report (`/api/pkgeval/reasons`); on Downloads a
  package box (daily requests, `/api/downloads/package/<name>`) and the most
  requested packages of the last week (`/api/downloads/top`), with names from
  the General registry (`registry_packages`). All API-only; the file copy
  hides them.

## Cost

~$30 to $35/month: instance ~$25, public IPv4 ~$4, 50 GB gp3 ~$4, S3/ECR/egress
under a dollar.

## Open decisions

1. SQLite on the box (recommended) vs RDS Postgres.
2. Serve the site from the box (recommended) vs Pages for HTML + AWS for data only.
3. Beta hostname, and who owns julialang.org DNS.
4. Start stage 0 now while the DNS/AWS questions settle?
