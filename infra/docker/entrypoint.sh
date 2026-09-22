#!/bin/bash
# Entry point of the ingest image. Paths inside the container:
#   /data        the host data directory: ci-timing.sqlite, export/, cache/
#   /site        where `sync-site` puts the static site for Caddy
set -uo pipefail

export CI_TIMING_DB="${CI_TIMING_DB:-/data/ci-timing.sqlite}"
export_dir="${CI_TIMING_EXPORT_DIR:-/data/export}"

# The fetchers clone under /app/.cache; keep that on the host
if [ -d /data/cache ] && [ ! -e /app/.cache ]; then
  ln -s /data/cache /app/.cache
fi

fetch_all() {
  # One failing source must not stop the others; the export then renders
  # that source as it was (the same rule the Actions workflow had).
  local failed=0
  for f in fetch_timing.jl fetch_benchmarks.jl fetch_pkgeval.jl fetch_packages.jl fetch_ttfx.jl fetch_agents.jl; do
    echo "==> $f"
    if ! julia --color=no --project "/app/$f"; then
      echo "!! $f failed" >&2
      failed=1
    fi
  done
  return $failed
}

export_all() {
  julia --color=no --project /app/db/export.jl --out "$export_dir" || return 1
  # The hand-maintained files are part of the repo, not the database
  cp /app/data/ttfx_annotations.json /app/data/methodology_changes.json "$export_dir/"
}

case "${1:-ingest}" in
  ingest)
    [ -s "$CI_TIMING_DB" ] || { echo "No database at $CI_TIMING_DB; restore or seed it first" >&2; exit 2; }
    fetch_all; rc=$?
    export_all || exit 1
    exit $rc
    ;;
  export)
    export_all
    ;;
  sync-site)
    # Everything the browser loads except data/, which the export writes
    rm -rf /site/assets /site/*.html /site/favicon.svg /site/site.webmanifest
    cp -r /app/index.html /app/favicon.svg /app/site.webmanifest /app/assets /site/
    for d in overview diff history timing builds commits workers ttfx downloads pkgeval; do
      rm -rf "/site/$d"; cp -r "/app/$d" "/site/$d"
    done
    commit="$(cat /app/BUILD_COMMIT 2>/dev/null || echo unknown)"
    sed -i "s|__BUILD_COMMIT__|$commit|g; s|__BUILD_COMMIT_SHORT__|${commit:0:7}|g" /site/index.html
    ;;
  datasette)
    shift; exec /opt/datasette/bin/datasette "$@"
    ;;
  api)
    # The site's API (db/serve.jl); CI_TIMING_DB names the database
    shift; exec julia --color=no --project /app/db/serve.jl --host 0.0.0.0 "$@"
    ;;
  julia)
    shift; exec julia --project "$@"
    ;;
  *)
    echo "usage: entrypoint.sh {ingest|export|sync-site|datasette ...|api ...|julia ...}" >&2; exit 64
    ;;
esac
