# Information for AI agents

This repo collects timing data for Julia CI runs. Beyond the website,
it ships a small set of Julia helper scripts under `analysis/` that turn
the raw history into something an agent can mine for optimization
opportunities in JuliaLang/julia or JuliaCI/BaseBenchmarks.jl.

## Where the data lives

The source of truth is a SQLite database on the site's host; the eight
`fetch_*.jl` scripts write to it every half hour (at :05 and :35 UTC). `docs/querying.md` is the
guide to reading it (tables by topic, example queries, conventions), and
`llms.txt`, served at `https://perf.julialang.org/llms.txt`, is the short
version for agents arriving at the site. Four ways in, cheapest first:

- **The API**: `https://perf.julialang.org/api/` lists every route with its
  parameters, generated from the route table in `src/api.jl` that the
  router uses (`db/serve.jl` is the command line entry point). It serves what the site's pages show, with a time window
  (`since`), gzipped and with ETags. `api/commit/<sha or PR number>` gathers
  one commit across every source. The shapes are the site's own and can
  change with it.
- **SQL over HTTP**: Datasette at `https://perf.julialang.org/db/`, public
  and read-only, limited to 2 s and 5000 rows per query. Table and column
  descriptions and a set of saved queries come from
  `db/datasette-metadata.json` (passed by `infra/docker/entrypoint.sh`).
- **The whole database**: `https://perf.julialang.org/data/ci-timing.sqlite.gz`,
  taken once a week (about 220 MB, 700 MB unpacked). Download once
  and run any SQL locally with `sqlite3`, no limits and no load on the host.
- **The extracts**: the gzipped JSON files described below, at
  `https://perf.julialang.org/data/<file>`, rendered from the database
  by `db/export.jl` after each ingest that changed them. The site itself reads the API, not
  these. `julia --project analysis/fetch_data.jl` downloads
  them all into `data/` (revalidating by ETag), which is what the analysis
  scripts and `tools/inspect-bench.mjs` read.

When you add or change an API route, give it a description and parameter
docs in the route table, and update `llms.txt` and `docs/querying.md` if
it is one an agent would reach for. When you add a table or column,
describe it in `db/datasette-metadata.json`.

Per-group BaseBenchmarks history is the extract
`data/benchmarks/<group>.json.gz`. Each file has the shape:

```text
{
  "minimum": {
    "benchmarks": { "<bench-name>": [t1_ns, t2_ns, ...], ... },
    "dates":      [...],
    "date_paths": [...],
    "commits":    [...]
  },
  "mean": { ... same shape ... }
}
```

The arrays are aligned: the i-th entry in any benchmark series
corresponds to the i-th `dates`/`commits` entry. `nothing` (or 0)
means the benchmark was missing on that date, so always filter
those out before computing anything. Times are nanoseconds.

TTFX history (the CI → TTFX tab) is `data/ttfx_summary.json.gz`, rendered
from what `fetch_ttfx.jl` records from the artifacts of the `TTFX` job on every julia-ci
master build (JuliaCI/julia-buildkite, `utilities/ttfx/`):

```text
{
  "metrics": ["precompile", "load", ...],
  "tasks":  ["Package/Task", ...],
  "builds": [ { "build", "job_id", "commit", "date", "version", "state",
                "tasks":  { "Package/Task": [precompile, load, run, warm, ...] },
                "failed": { "Package/Task": "error" } }, ... ]
}
```

Each task's array follows the file's `metrics` list. Times are seconds,
the minimum over the job's ABBA blocks; `load` and `run` are the cold
first run of the task script, `warm` the best total of the later runs,
and the `_gcoff` ones the same from repeats with the GC disabled. Then
come counts: `invalidated`, the MethodInstances the task script
invalidated (from an untimed run that logs them; null for jobs before
the driver did), and from the job's trace logs (`trace-compile.tar.gz`)
`recompiled`, the methods compiled again because an invalidation had
dropped their code, with their compile seconds `recompile_s`; a job
without trace logs has the array end before them. `api/ttfx/job/<job_id>`
has the recompiled statements and the top causes of the invalidations.
`builds` is sorted by date. A build whose job failed
before uploading has an empty `tasks`. `releases` is a second array of
the same shape for the weekly `TTFX release` job, which measures the
newest stable release on the same tasks and machines as a reference;
its `version` and `commit` are the release's. The site draws it as a
separate series and computes nothing else from it. `lts` is the same for the
weekly `TTFX lts` job, which measures the newest patch release of the LTS series,
and `branch_nightly` for the weekly `TTFX branch nightly` job, which measures the
nightly of the next release's branch (its `version` is the nightly's). A week
when no release branch is ahead of the latest release has no entry. Once that
branch has commits of its own, julia-ci measures each of its builds too; those
jobs have kind `release_branch` in the database and join `branch_nightly`.
`opt` is a third array of the same shape for the `TTFX opt` job of the daily
schedule, which measures the nightly optimized build (PGO and ThinLTO) against
the regular master build of the same commit, interleaved in the same job. Each
entry adds `base`, the regular build's times per task (the time metrics only,
from the job's `base` samples), so `tasks[t][i] / base[t][i]` is the paired
effect of the optimizations. The site draws the optimized build as a separate
series and shows the paired difference in its tooltip and details.

The TTFX job also runs on julia-pr builds of pull requests that touch the
paths it watches, comparing the head with the master build of the merge-base
and uploading `ttfx/compare.json`. `fetch_ttfx.jl` keeps only the latest
comparison of each open pull request, in `ttfx_prs` (no history: a closed
pull request's row is deleted), and `api/ttfx/prs` ranks them for the TTFX
tab's "Open PRs" table. It lists the open pull requests from GitHub
anonymously, which makes it the largest user of the 60 requests an hour GitHub
allows the host (`GITHUB_TOKEN` is used if set).

Hand-written notes on individual TTFX jobs live in `data/ttfx_annotations.json`
(not touched by `fetch_ttfx.jl`; the site reads it, and
`data/methodology_changes.json`, from `api/notes/<name>`, served from the
deployed code, so an edit is live as soon as the deploy is): each entry names a `job_id` from the summary
plus a short `label` and a fuller `description`. The site draws a dashed line
with the label at that job on every TTFX chart, shows the full text while the
pointer is over the line or label, adds it to the build's tooltip, and flags
the row in the builds table. Use it for changes to the runners or to the
benchmark itself that shift the numbers without a Julia commit being
responsible: a macOS update on the agents, a change to how the driver runs the
task scripts.
An optional `kind` colours the line and its label by what changed: `runner`
(the CI machines: an OS update, the object cache), `driver` (how the TTFX job
measures) or `packages` (a package release a task resolved); a note without
one is grey.
An optional `url` links the change (a pull request, say): the build's popup
links it and clicking the line opens it.
An optional `tasks` list names the tasks the change affected. The TTFX tab's
"Hide annotated jumps" toggle (`th=1`) scales each series before an annotated
job by the step it measures there, over all tasks or just the listed ones.
An optional `versions` range, `{ "min": "1.14" }` with `max` too if needed
(both inclusive; a bound such as `1.14` covers every 1.14 patch and
prerelease), limits that to the runs of those Julia versions. Use it for a
change that only some versions see, so the release and LTS series are not
scaled by a step they never had: the object cache, for one, is 1.14 and later.

Agent snapshots (the CI → Workers tab) live under `data/agents/`, rendered
from what `fetch_agents.jl` records from the Buildkite agents API on every
ingest. `history-YYYY-MM.ndjson` has one line per run, and each export
rewrites every month file in full:

```text
{ "time": "2026-09-12T02:00:00Z", "connected": ["<agent name>", ...] }
```

and `latest.json` holds the latest details of every agent seen in the
last year, keys sorted:

```text
{ "generated_at": "...",
  "agents": { "<agent name>": { "hostname", "queue", "os", "arch", "version",
                                "state", "connected_at", "first_seen", "last_seen",
                                "job": { "name", "pipeline", "build", "started_at" } | null } } }
```

`state` is the API's connection state at the last listing and `job` is
only set for agents connected in the latest snapshot. Month files older
than a year are not rendered.

The `build`, `test` and `launch` queues (the Julia cluster) and the Secure
cluster's `default` queue have no resident agents: each host's scheduler (JuliaCI/sandboxed-buildkite-agent) starts one
agent per job with `--acquire-job`, named `<group>-<host>.<slot>`, and it
disconnects when the job ends. A snapshot only lists the slots mid-job, so
an absent `tester-amdci4.3` means an idle slot, not a down host; the site
folds those names per host and flags a host only after days without a job.

`fetch_agents.jl` also records every runnable job of julia-pr and julia-ci
builds in `pool_jobs` (kept 60 days, backfilled 30 on the first run), with the
pool it asked for (the queue, os and arch of its agent query rules) and when it
became runnable, started and finished. `api/agents/backlog` samples from it how
many jobs wait for each pool and for how long, which the Workers tab charts as
the queue backlog. `api/agents/usage` sums the agent time of the jobs that
finished in the last 7 days, which the Timing tab's Worker time view
(`?tab=ci-timing&jv=usage`) splits by pipeline, job type, OS and so on;
clicking slices filters the other charts (`jf=os.Linux~queue.test`).

Repository activity (the Repo → Activity tab) comes from `fetch_github.jl`:
`gh_items` holds every issue and pull request of JuliaLang/julia as GitHub lists
it now, and `commits` the master commits. `api/github/activity` renders per-day series
from them: open counts, opened/closed/merged and commits per day, and over a
trailing 30 days the distinct commit authors and PR openers and the median
days to merge. A reopened item keeps only its latest close, so the open
counts are slightly off for items that were closed and reopened.

## Analysis helpers (`analysis/`)

All scripts activate the repo's `Project.toml` automatically. Run
from the repo root with the bundled juliaup (`julia +nightly` is
fine).

### `BenchHistory.jl`

Library module. Import with:

```julia
# in `julia --project`, from the repository root
include("analysis/BenchHistory.jl"); using .BenchHistory
```

Useful exports:

- `load_group(name)` — read one gzipped JSON file into a `JSON3` view.
- `all_groups()` — list groups with on-disk data.
- `all_benches([groups]; stat=:minimum)` — channel of
  `(group, bench, raw_series)` tuples across the corpus.
- `clean_times(v)` — drop `nothing`/0 entries, return `Vector{Float64}`.
- `recent_minimum(v; n=10)` — minimum of the last `n` valid samples.
  It hides a step up in the last few samples.
- `recent_level(v; n=20, step=0.2)`: median of the valid samples since the
  last step of more than `step` (20%) among the last `n`, so a recent
  regression shows. `find_family_outliers` ranks by it.
- `noise_pct(v; n=20)` — median |Δlog| over recent samples, in percent.
  A practical "is this benchmark stable enough to trust?" signal.
- `family_key(name)` — strip type tokens (`Int64`, `Float32`, ...) and
  long integer literals so that variants of the same benchmark map
  to the same key.
- `find_family_outliers(; ratio=5, min_time_ns=100, ...)` — return
  variants whose `recent_level` is `ratio`× the median of their family.
  This is the main hook for finding suspicious type specializations.

### `find_outliers.jl`

CLI wrapper around `find_family_outliers`. Examples:

```sh
julia analysis/find_outliers.jl
julia analysis/find_outliers.jl --ratio 10 --min-ns 500
julia analysis/find_outliers.jl --groups array,union,scalar --limit 100
```

### `top_slow.jl`

Slowest benchmarks per group, after dropping BigInt/BigFloat (they
dominate by GMP cost, not codegen):

```sh
julia analysis/top_slow.jl array         # top 25 in `array`
julia analysis/top_slow.jl array 50      # top 50
julia analysis/top_slow.jl --all 10      # top 10 in every group
```

### `show_history.jl`

Dump the time series for a benchmark with commit hashes, annotating
step changes >10% so a regression can be bisected:

```sh
julia analysis/show_history.jl array "sub2ind"
julia analysis/show_history.jl tuple "longtuple"
julia analysis/show_history.jl array "sumlinear_view" mean
```

## Dashboard inspector (`tools/inspect-bench.mjs`)

Node CLI that reproduces what the website's bench chart computes
(including the time range, with `--days`),
using the same shared module (`assets/bench-core.js`) that the
browser loads. Use it when you want to diagnose a discrepancy
between the group geomean line and the individual benchmark lines
on the live dashboard without opening a browser.

```sh
node tools/inspect-bench.mjs                  # sparse, minimum, all dates
node tools/inspect-bench.mjs sparse mean
node tools/inspect-bench.mjs array minimum --days 15   # the site's default range
```

It prints:

1. The group geomean series in the range in ns and as `%` from
   baseline (the first point in the range). Like the chart's group and
   "Overall" lines it is chain-linked: each step is the geomean of the
   benchmarks' ratios to their previous sample, so a benchmark missing
   on some dates, or added or removed, does not make the line jump. The
   ns value is the first date's geomean carried forward by those steps.
2. A table of per-benchmark `%` from baseline at the three most
   recent dates, sorted by `|last %|` — i.e. the benchmarks moving
   the chart most. Benchmarks with an entry in
   `data/methodology_changes.json` are flagged; like the chart, the CLI
   does not cut their series at the change (the chart only fades the
   older points), so their `%` can be huge over a long range.
3. A spread summary (`min / p25 / median / p75 / max`) of the
   per-benchmark `%` at each recent date, alongside the geomean
   line's `%`. If those columns disagree, the geomean line is not
   representing the visible benchmarks.

The shared logic (the methodology-change registry, series construction,
baselining) lives in `assets/bench-core.js` so the CLI and the
browser stay in sync; do not duplicate that math elsewhere.

## Suggested workflow for finding optimization candidates

1. `find_outliers.jl` to surface variants that are dramatically
   slower than their siblings (often a missed specialization).
2. `top_slow.jl <group>` for absolute outliers within a group.
3. `show_history.jl <group> <name>` to confirm the slowness is
   stable and to spot the commit where a regression entered.
4. Reproduce locally with `BenchmarkTools.@btime` against the same
   commit (or `julia +nightly`) before writing a fix.
5. Record findings in the JuliaLang/julia issue or PR that acts on them.

## These scripts are not finished

They are deliberately small. Improvements that would help future
agents include:

- A "regression detector" that walks each series with changepoint
  detection and reports the most recent step.
- Cross-version comparison (the benchmark data is master only; a
  release series would let us compare nightly vs release on the
  same benchmark).
- Correlating regressions with the commits in each report's range.
  `api/commit/<ref>` and `bench_reports.baseline_commit_sha` give the
  range; the `commits` table (subjects, authors, PR numbers) has master's
  commits from `fetch_github.jl`.
- Filtering by inferred noise floor (`noise_pct`) so we don't chase
  benchmarks that bounce ±20% run to run.

If you extend the scripts, keep them dependency-light (just what is
already in `Project.toml`) and runnable as standalone CLIs. Update
this file with whatever new entry points you add.

## When invoked by an automation

- Read data with the helpers in `BenchHistory.jl`; do not parse
  the JSON yourself.
- Always drop `nothing`/0 before computing statistics.
- Don't extrapolate from a single sample; use `recent_level` or
  `recent_minimum` over at least the last 5–10 points.
- Cross-check any candidate against `show_history.jl` before
  claiming a regression — many "outliers" are simply noisy
  benchmarks, not real regressions.
