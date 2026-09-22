# Julia Performance Tracking

Dashboard for Julia language performance: Nanosoldier benchmark reports every 2 to 3 days,
[CI build/test timing](https://buildkite.com/julialang/julia-ci), TTFX, PkgEval and
package-server downloads. The Overview tab sums up every source; the other tabs go deep.

**Live:** <https://perf.julialang.org/>

Short paths open a tab directly and forward any other query parameters:
[/overview](https://perf.julialang.org/overview),
[/diff](https://perf.julialang.org/diff), [/history](https://perf.julialang.org/history),
[/timing](https://perf.julialang.org/timing), [/builds](https://perf.julialang.org/builds),
[/workers](https://perf.julialang.org/workers), [/ttfx](https://perf.julialang.org/ttfx),
[/downloads](https://perf.julialang.org/downloads), [/pkgeval](https://perf.julialang.org/pkgeval).
Each is a small redirect page under a directory of that name; the `?tab=` URLs
they resolve to keep working as before.

## How it works

One EC2 host (`infra/terraform/`, see its README) runs everything from one
container image (`Dockerfile`):

- Six fetchers write a SQLite database every hour (`db/schema.sql`):
  - `fetch_timing.jl`: Buildkite job timings (`julia-ci`, plus the legacy
    `julia-master` and `julia-master-scheduled` pipelines, which stopped
    receiving builds in July 2026)
  - `fetch_benchmarks.jl`: Nanosoldier benchmark history, every estimate of
    every benchmark and Nanosoldier's own verdicts
  - `fetch_pkgeval.jl`: PkgEval reports, with every package's outcome
  - `fetch_ttfx.jl`: TTFX results (package precompile, load and run times of the
    [Julia-TTFX-Snippets](https://github.com/tecosaur/Julia-TTFX-Snippets) tasks,
    the load and run times also from repeats with the GC disabled)
    from the `TTFX` job on every `julia-ci` master build, see
    [julia-buildkite/utilities/ttfx](https://github.com/JuliaCI/julia-buildkite/tree/main/utilities/ttfx)
  - `fetch_packages.jl`: package-server download rollups, per package too,
    with names from the General registry
  - `fetch_agents.jl`: a snapshot of the connected Buildkite agents on every
    run (the token needs the `read_agents` scope)
- `db/serve.jl` is the site's API (`/api/`): the shapes in `db/Render.jl`,
  served with a time window so the browser loads what it shows.
- `db/export.jl` renders the same shapes to files after every run, published
  at `/data/` for scripts; `analysis/fetch_data.jl` downloads them.
- Datasette serves the database read-only at `/db/`, and `/data/ci-timing.sqlite.gz`
  is a snapshot of the whole thing. `AGENTS.md` has the details.

Pushing to `main` builds the image and deploys it (`.github/workflows/deploy.yml`);
`health.yml` checks the host once a day. The plan and its history:
`docs/database-migration.md`.

To run the site locally, download the snapshot and serve it:

```sh
curl -O https://perf.julialang.org/data/ci-timing.sqlite.gz && gunzip ci-timing.sqlite.gz
julia --project db/serve.jl --db ci-timing.sqlite --site .
```

## Related

The "Benchmarks" tab embeds [julia-perf](https://github.com/JuliaCI/julia-perf),
a fork of [rust-lang/rustc-perf](https://github.com/rust-lang/rustc-perf)
adapted for Julia. Thanks to the Rust team for their work on that project.

## Analytics

The site counts visits with Google Analytics, one page view per tab shown
(`/overview`, `/timing`, ...). Filters and selections, which live in the query
string, are never sent. Nothing is loaded when the browser sends Do Not Track
or Global Privacy Control, or on a local checkout.

## License

MIT, see [LICENSE](LICENSE).
