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

# A git transfer that stalls is dropped rather than left to hang the run
export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60

fetch_all() {
  # One failing source must not stop the others; the export then renders
  # that source as it was (the same rule the Actions workflow had). Each
  # fetcher gets its own time limit (the slowest takes about 10 minutes), so
  # one that hangs does not use up the whole run's.
  local failed=0
  for f in fetch_timing.jl fetch_benchmarks.jl fetch_pkgeval.jl fetch_packages.jl fetch_ttfx.jl fetch_sizes.jl fetch_agents.jl fetch_github.jl; do
    echo "==> $f"
    if ! timeout --kill-after=1m 30m julia --color=no --project "/app/$f"; then
      echo "!! $f failed" >&2
      failed=1
    fi
  done
  return $failed
}

export_all() {
  local rc=0
  julia --color=no --project /app/db/export.jl --out "$export_dir" || rc=1
  # The hand-maintained files are part of the repo, not the database. The site
  # reads them from the API (api/notes/<name>), which always has the deployed
  # code's; these copies, from whatever image this run started on, are for
  # readers of /data/ and can lag a deploy by a run.
  cp /app/data/ttfx_annotations.json /app/data/methodology_changes.json "$export_dir/" || rc=1
  return $rc
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
    # Everything the browser loads except data/, which the export writes. It
    # is copied beside the live site and renamed into place, so a request
    # during the sync never finds a file missing or half written.
    (
      set -e
      stage=/site/.sync-new; old=/site/.sync-old
      rm -rf "$stage" "$old"; mkdir "$stage" "$old"
      cp -r /app/index.html /app/favicon.svg /app/site.webmanifest /app/llms.txt /app/robots.txt /app/assets "$stage/"
      # Every page directory, so a new tab needs no change here
      for index in /app/*/index.html; do cp -r "$(dirname "$index")" "$stage/"; done
      commit="$(cat /app/BUILD_COMMIT 2>/dev/null || echo unknown)"
      sed -i "s|__BUILD_COMMIT__|$commit|g; s|__BUILD_COMMIT_SHORT__|${commit:0:7}|g" "$stage/index.html"
      # A top-level page the image no longer ships goes too
      for f in /site/*.html; do
        if [ -e "$f" ] && [ ! -e "$stage/${f##*/}" ]; then mv "$f" "$old/"; fi
      done
      for p in "$stage"/*; do
        name="${p##*/}"
        # A file is replaced in one rename; a directory is moved aside first
        if [ -d "/site/$name" ]; then mv "/site/$name" "$old/"; fi
        mv -f "$p" "/site/$name"
      done
      rm -rf "$stage" "$old"
    )
    ;;
  datasette)
    # The table descriptions and saved queries ship with the image; the host's
    # unit only passes the database and settings, so it needs no change
    shift
    [ "${1:-}" = serve ] && set -- "$@" --metadata /app/db/datasette-metadata.json
    exec /opt/datasette/bin/datasette "$@"
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
