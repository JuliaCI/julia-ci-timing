using PrecompileTools

# A server over an in-memory database holding the schema and the newest few
# rows of a real one (db/precompile_fixture.sql, from db/make_fixture.jl), so
# every route renders with the row types the live data has
const FIXTURE = joinpath(dirname(@__DIR__), "db", "precompile_fixture.sql")
include_dependency(FIXTURE)
include_dependency(Store.SCHEMA_FILE)

function fixture_server()
    db = Store.open_db(":memory:")
    # The rows are a sample, so a parent a row points to may be absent
    SQLite.execute(db, "PRAGMA foreign_keys = OFF")
    for line in eachline(FIXTURE)
        (isempty(line) || startswith(line, "--")) && continue
        SQLite.execute(db, line)
    end
    pool = Channel{SQLite.DB}(1)
    put!(pool, db)
    return Server(pool, ReentrantLock(), Dict(), String[], 0, nothing, nothing, 0.0, Dict(), false)
end

@setup_workload begin
    s = fixture_server()
    targets = vcat(landing_targets(), withdb(other_targets, s),
                   ["/api/", "/api/status", "/api/ready", "/api/no/such/route", "/api/timing/runs?since=yesterday"])
    @compile_workload begin
        for target in targets
            handle(s, HTTP.Request("GET", target, ["Accept-Encoding" => "gzip"]))
        end
        # A client without gzip, a revalidation, and the paths beside /api/
        handle(s, HTTP.Request("GET", "/api/ttfx/summary"))
        handle(s, HTTP.Request("GET", "/api/ttfx/summary", ["If-None-Match" => "W/\"0-$(BUILD_ID[])\""]))
        handle(s, HTTP.Request("GET", "/healthz"))
        handle(s, HTTP.Request("GET", "/index.html"))
        refresh_stale!(s)
    end
end
