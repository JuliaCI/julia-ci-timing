# Julia Performance

Dashboard for Julia language performance: nightly benchmarks (Nanosoldier),
[CI build/test timing](https://buildkite.com/julialang/julia-ci), and PkgEval results.

**Live:** <https://JuliaCI.github.io/julia-ci-timing/> (also at <https://perf.julialang.org/>)

## Data

Fetched by the Julia scripts in this repo and cached under `data/`:

- `fetch_benchmarks.jl` — Nanosoldier benchmark history
- `fetch_pkgeval.jl` — PkgEval reports
- `fetch_packages.jl` — Package download aggregates from public package-server rollups
- `fetch_timing.jl` — Buildkite job timings (`julia-ci`, plus the legacy
  `julia-master` and `julia-master-scheduled` pipelines, which stopped
  receiving builds in July 2026)

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
