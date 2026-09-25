# Information for AI agents

This repo collects timing data for Julia CI runs. Beyond the website,
it ships a small set of Julia helper scripts under `analysis/` that turn
the raw history into something an agent can mine for optimization
opportunities in JuliaLang/julia or JuliaCI/BaseBenchmarks.jl.

## Where the data lives

The source of truth is a SQLite database on the site's host; the six
`fetch_*.jl` scripts write to it every hour. `docs/querying.md` is the
guide to reading it (tables by topic, example queries, conventions), and
`llms.txt`, served at `https://perf.julialang.org/llms.txt`, is the short
version for agents arriving at the site. Four ways in, cheapest first:

- **The API**: `https://perf.julialang.org/api/` lists every route with its
  parameters, generated from the route table in `db/serve.jl` that the
  router uses. It serves what the site's pages show, with a time window
  (`since`), gzipped and with ETags. `api/commit/<sha or PR number>` gathers
  one commit across every source. The shapes are the site's own and can
  change with it.
- **SQL over HTTP**: Datasette at `https://perf.julialang.org/db/`, public
  and read-only, limited to 2 s and 5000 rows per query. Table and column
  descriptions and a set of saved queries come from
  `db/datasette-metadata.json` (passed by `infra/docker/entrypoint.sh`).
- **The whole database**: `https://perf.julialang.org/data/ci-timing.sqlite.gz`,
  taken after every ingest (about 220 MB, 700 MB unpacked). Download once
  and run any SQL locally with `sqlite3`, no limits and no load on the host.
- **The extracts**: the gzipped JSON files described below, at
  `https://perf.julialang.org/data/<file>`, rendered from the database
  after every ingest. `julia --project analysis/fetch_data.jl` downloads
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

TTFX history (the CI → TTFX tab) is `data/ttfx_summary.json.gz`, written
by `fetch_ttfx.jl` from the artifacts of the `TTFX` job on every julia-ci
master build (JuliaCI/julia-buildkite, `utilities/ttfx/`):

```text
{
  "tasks":  ["Package/Task", ...],
  "builds": [ { "build", "job_id", "commit", "date", "version", "state",
                "tasks":  { "Package/Task": [precompile, load, run, warm] },
                "failed": { "Package/Task": "error" } }, ... ]
}
```

Times are seconds, the minimum over the job's ABBA blocks; `load` and
`run` are the cold first run of the task script, `warm` the best total
of the later runs. `builds` is sorted by date. A build whose job failed
before uploading has an empty `tasks`.

The TTFX job also runs on julia-pr builds of pull requests that touch the
paths it watches, comparing the head with the master build of the merge-base
and uploading `ttfx/compare.json`. `fetch_ttfx.jl` keeps only the latest
comparison of each open pull request, in `ttfx_prs` (no history: a closed
pull request's row is deleted), and `api/ttfx/prs` ranks them for the TTFX
tab's "Open PRs" table. It lists the open pull requests from GitHub
anonymously (about a dozen requests an hour; `GITHUB_TOKEN` is used if set).

Hand-written notes on individual TTFX jobs live in `data/ttfx_annotations.json`
(not touched by `fetch_ttfx.jl`): each entry names a `job_id` from the summary
plus a short `label` and a fuller `description`. The site draws a dashed line
with the label at that job on every TTFX chart, shows the full text while the
pointer is over the line or label, adds it to the build's tooltip, and flags
the row in the builds table. Use it for changes to the runners or to the
benchmark itself that shift the numbers without a Julia commit being
responsible: a macOS update on the agents, a change to how the driver runs the
task scripts.

Agent snapshots (the CI → Workers tab) live under `data/agents/`, written
by `fetch_agents.jl` from the Buildkite agents API on every update run.
`history-YYYY-MM.ndjson` is append-only, one line per run:

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

## Analysis helpers (`analysis/`)

All scripts activate the repo's `Project.toml` automatically. Run
from the repo root with the bundled juliaup (`julia +nightly` is
fine).

### `BenchHistory.jl`

Library module. Import with:

```julia
include("analysis/BenchHistory.jl"); using .BenchHistory
```

Useful exports:

- `load_group(name)` — read one gzipped JSON file into a `JSON3` view.
- `all_groups()` — list groups with on-disk data.
- `all_benches([groups]; stat=:minimum)` — channel of
  `(group, bench, raw_series)` tuples across the corpus.
- `clean_times(v)` — drop `nothing`/0 entries, return `Vector{Float64}`.
- `recent_minimum(v; n=10)` — minimum of the last `n` valid samples.
- `noise_pct(v; n=20)` — median |Δlog| over recent samples, in percent.
  A practical "is this benchmark stable enough to trust?" signal.
- `family_key(name)` — strip type tokens (`Int64`, `Float32`, ...) and
  long integer literals so that variants of the same benchmark map
  to the same key.
- `find_family_outliers(; ratio=5, min_time_ns=100, ...)` — return
  variants that are `ratio`× slower than the median of their family.
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

Node CLI that reproduces what the website's bench chart computes,
using the same shared module (`assets/bench-core.js`) that the
browser loads. Use it when you want to diagnose a discrepancy
between the group geomean line and the individual benchmark lines
on the live dashboard without opening a browser.

```sh
node tools/inspect-bench.mjs                  # sparse, minimum
node tools/inspect-bench.mjs sparse mean
node tools/inspect-bench.mjs array minimum
```

It prints:

1. The post-cutoff group geomean series in ns and as `%` from
   baseline (the first post-cutoff point).
2. A table of per-benchmark `%` from baseline at the three most
   recent dates, sorted by `|last %|` — i.e. the benchmarks moving
   the chart most.
3. A spread summary (`min / p25 / median / p75 / max`) of the
   per-benchmark `%` at each recent date, alongside the geomean
   line's `%`. If those columns disagree, the geomean line is not
   representing the visible benchmarks.

The shared logic (methodology-change cutoffs, series construction,
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
- Cross-version comparison (only the 1.13 manifest is wired up; an
  `--branch` flag would let us compare nightly vs release on the
  same benchmark).
- Correlating regressions with the commits in each report's range.
  `api/commit/<ref>` and `bench_reports.baseline_commit_sha` give the
  range; the `commits` table (subjects, authors, PR numbers from a clone
  of JuliaLang/julia) is still empty.
- Filtering by inferred noise floor (`noise_pct`) so we don't chase
  benchmarks that bounce ±20% run to run.

If you extend the scripts, keep them dependency-light (just what is
already in `Project.toml`) and runnable as standalone CLIs. Update
this file with whatever new entry points you add.

## When invoked by an automation

- Read data with the helpers in `BenchHistory.jl`; do not parse
  the JSON yourself.
- Always drop `nothing`/0 before computing statistics.
- Don't extrapolate from a single sample; use `recent_minimum` (or
  similar) over at least the last 5–10 points.
- Cross-check any candidate against `show_history.jl` before
  claiming a regression — many "outliers" are simply noisy
  benchmarks, not real regressions.
