#!/usr/bin/env julia
# The site's API from the command line. The server is the CITiming package
# in src/ (src/api.jl has the route table, the cache and the request
# handling), precompiled with its routes when the image is built.
#
#   julia --project db/serve.jl [--db PATH] [--host 127.0.0.1] [--port 8002] [--site DIR] [--data DIR] [--notes DIR]
#
# GET /api/ lists every route with its parameters. --site DIR and --data DIR
# serve the static site and the extracts too, for local development; on the
# host Caddy does that. --notes DIR serves the hand-maintained notes found in
# DIR (runtime_annotations.json, say) in place of the repository's data/ ones,
# for a preview over generated data.

using Pkg
Pkg.activate(dirname(@__DIR__); io=devnull)
using CITiming

abspath(PROGRAM_FILE) == (@__FILE__) && CITiming.main(ARGS)
