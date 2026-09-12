# Julia Performance

Dashboard for Julia language performance: nightly benchmarks (Nanosoldier),
[CI build/test timing](https://buildkite.com/julialang/julia-ci) and TTFX results, and PkgEval results.

**Live:** <https://JuliaCI.github.io/julia-ci-timing/> (also at <https://perf.julialang.org/>)

Short paths open a tab directly and forward any other query parameters:
[/diff](https://perf.julialang.org/diff), [/history](https://perf.julialang.org/history),
[/timing](https://perf.julialang.org/timing), [/commits](https://perf.julialang.org/commits),
[/workers](https://perf.julialang.org/workers), [/ttfx](https://perf.julialang.org/ttfx),
[/downloads](https://perf.julialang.org/downloads), [/pkgeval](https://perf.julialang.org/pkgeval).
Each is a small redirect page under a directory of that name; the `?tab=` URLs
they resolve to keep working as before.

## Data

Fetched by the Julia scripts in this repo and cached under `data/`:

- `fetch_benchmarks.jl` — Nanosoldier benchmark history
- `fetch_pkgeval.jl` — PkgEval reports
- `fetch_packages.jl` — Package download aggregates from public package-server rollups
- `fetch_timing.jl` — Buildkite job timings (`julia-ci`, plus the legacy
  `julia-master` and `julia-master-scheduled` pipelines, which stopped
  receiving builds in July 2026)
- `fetch_ttfx.jl` — TTFX results (package precompile, load and run times of the
  [Julia-TTFX-Snippets](https://github.com/tecosaur/Julia-TTFX-Snippets) tasks)
  from the `TTFX` job on every `julia-ci` master build, see
  [julia-buildkite/utilities/ttfx](https://github.com/JuliaCI/julia-buildkite/tree/main/utilities/ttfx)
- `fetch_agents.jl` — a snapshot of the connected Buildkite agents on every run
  (the token needs the `read_agents` scope), appended as one line to a monthly
  `data/agents/history-*.ndjson`, for the Workers tab's live agent table and
  connected-agents-per-queue history

## PR comparison

```bash
export BUILDKITE_API_TOKEN="your-token"
julia --project=. compare_build.jl <build_number> [--threshold 10] [--json|--markdown]
```

Exit codes: `0` no regressions, `1` regressions, `2` error.
See [ci-timing-check.yml](ci-timing-check.yml) for the GitHub Actions workflow.

## Related

The "Benchmarks" tab embeds [julia-perf](https://github.com/JuliaCI/julia-perf),
a fork of [rust-lang/rustc-perf](https://github.com/rust-lang/rustc-perf)
adapted for Julia. Thanks to the Rust team for their work on that project.

## License

MIT
