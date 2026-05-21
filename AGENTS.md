# Information for AI agents

This repo collects timing data for Julia CI runs. Beyond the website,
it ships a small set of Julia helper scripts under `analysis/` that turn
the raw history into something an agent can mine for optimization
opportunities in JuliaLang/julia or JuliaCI/BaseBenchmarks.jl.

## Where the data lives

Per-group BaseBenchmarks history is stored as gzipped JSON under
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
5. Track findings in `docs/codegen-opportunities.md`.

## These scripts are not finished

They are deliberately small. Improvements that would help future
agents include:

- A "regression detector" that walks each series with changepoint
  detection and reports the most recent step.
- Cross-version comparison (only the 1.13 manifest is wired up; an
  `--branch` flag would let us compare nightly vs release on the
  same benchmark).
- Group-level summaries (e.g. geomean over time) so we can plot a
  single "is the suite getting faster or slower" line.
- Correlating regressions with `julia/` commit metadata pulled from
  the `.julia-repo-cache/` worktree.
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
