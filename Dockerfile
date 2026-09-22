# Ingest image for perf.julialang.org: the fetchers, the export and the site's
# static files. Built by .github/workflows/deploy.yml for linux/arm64 and run
# on the host by the ci-timing-ingest timer (infra/terraform/files).
# Pinned to the patch Manifest.toml was resolved with. Dependabot proposes
# the bump; re-resolve the Manifest under the new version with it
FROM julia:1.12.7

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates python3 python3-venv \
 && rm -rf /var/lib/apt/lists/*

# Fixed unprivileged identity, matching the host's data directory ownership
ARG RUNTIME_UID=10001
ARG RUNTIME_GID=10001
RUN groupadd -g ${RUNTIME_GID} ci-timing && useradd -m -u ${RUNTIME_UID} -g ${RUNTIME_GID} ci-timing

# The trailing colon keeps the bundled depot (precompiled stdlibs) on the path.
# The package images are compiled here for the host's CPU (Graviton2 is
# neoverse-n1) with a generic fallback: the build runner is a newer Neoverse,
# and an image compiled for it is rejected on the host, which then
# recompiled every package on every run.
ENV JULIA_DEPOT_PATH=/depot: \
    JULIA_PROJECT=/app \
    JULIA_NUM_THREADS=2 \
    JULIA_CPU_TARGET="generic;neoverse-n1,clone_all"

WORKDIR /app
# Dependencies first, so source-only changes reuse the instantiated layer;
# the tracked Manifest pins every package version, so an image build never
# resolves anew
COPY Project.toml Manifest.toml ./
RUN julia -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'
# Datasette serves the public read-only /db/ from this same image: the
# official datasette image has no arm64 build. After the Julia layers, so
# a Datasette bump does not rebuild them.
COPY infra/docker/requirements.txt /opt/datasette-requirements.txt
RUN python3 -m venv /opt/datasette && /opt/datasette/bin/pip install --no-cache-dir -r /opt/datasette-requirements.txt
COPY . .
# Compile the store once so its cache is in the image, then hand everything
# to the runtime user (Julia writes compile caches and logs under the depot)
RUN julia -e 'include("db/Store.jl")' && chown -R ci-timing:ci-timing /depot /app

USER ci-timing
ENTRYPOINT ["/app/infra/docker/entrypoint.sh"]
CMD ["ingest"]
