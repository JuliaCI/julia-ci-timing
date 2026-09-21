# Ingest image for perf.julialang.org: the fetchers, the export and the site's
# static files. Built by .github/workflows/deploy.yml for linux/arm64 and run
# on the host by the ci-timing-ingest timer (infra/terraform/files).
FROM julia:1.12

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates python3 python3-venv \
 && rm -rf /var/lib/apt/lists/*

# Datasette serves the public read-only /db/ from this same image: the
# official datasette image has no arm64 build.
ARG DATASETTE_VERSION=0.65.5
RUN python3 -m venv /opt/datasette && /opt/datasette/bin/pip install --no-cache-dir "datasette==${DATASETTE_VERSION}"

# Fixed unprivileged identity, matching the host's data directory ownership
ARG RUNTIME_UID=10001
ARG RUNTIME_GID=10001
RUN groupadd -g ${RUNTIME_GID} ci-timing && useradd -m -u ${RUNTIME_UID} -g ${RUNTIME_GID} ci-timing

ENV JULIA_DEPOT_PATH=/depot \
    JULIA_PROJECT=/app \
    JULIA_NUM_THREADS=2

WORKDIR /app
# Dependencies first, so source-only changes reuse the instantiated layer
COPY Project.toml ./
RUN julia -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'
COPY . .
# Compile the store once so its cache is in the image, then hand everything
# to the runtime user (Julia writes compile caches and logs under the depot)
RUN julia -e 'include("db/Store.jl")' && chown -R ci-timing:ci-timing /depot /app

USER ci-timing
ENTRYPOINT ["/app/infra/docker/entrypoint.sh"]
CMD ["ingest"]
