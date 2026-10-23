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
    return Server(pool, pool, ReentrantLock(), Dict(), 0, nothing, nothing, 0.0, Dict(), false, 0.0, "")
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
        fill_landing!(s)
        # The fetchers load the store from this package, so its write path is compiled here too
        db = Store.open_db(":memory:")
        Store.source_run(db, "timing") do
            Store.transaction(db) do
                stmt = Store.upsert_stmt(db, "coverage", ["commit_sha"], ["measured_at", "codecov", "coveralls"])
                Store.upsert!(stmt, ("0"^40, Store.iso_now(), 1.0, missing, Store.next_seq!(db)))
            end
            length(Store.query(db, "SELECT * FROM coverage"))
        end
        close(db)
    end
end
