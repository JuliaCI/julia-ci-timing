"""
CITiming: the API behind perf.julialang.org (`/api/`), served from the
SQLite database the fetchers write. `db/serve.jl` is the command line entry
point; `src/api.jl` has the route table, the cache and the request handling.

A package rather than a script so that its code is compiled when the image
is built (`src/precompile.jl` renders every route over a fixture database)
instead of by the first visitors after a deploy.
"""
module CITiming

# The store and the renderer are shared with the fetchers and the exporter,
# which include them as scripts; the package includes the same files
include(joinpath(@__DIR__, "..", "db", "Store.jl"))
using .Store
include(joinpath(@__DIR__, "..", "db", "Render.jl"))
using .Render
using HTTP, SQLite, JSON3, CodecZlib, Dates, DataStructures

include("api.jl")

function __init__()
    BUILD_ID[] = build_id()
end

include("precompile.jl")

end # module
