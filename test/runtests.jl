# Checks the CI workflow runs on every push and pull request, over the
# precompile fixture (db/precompile_fixture.sql), so no network or real
# database is needed:
#
#   julia --project test/runtests.jl
#
# Every API route renders without a server error, the export writes its
# files, every fetcher and script loads, and the Datasette metadata names
# only tables, columns and queries the schema has.

using Test
using CITiming, CITiming.Store, HTTP, JSON3, SQLite, CodecZlib

const ROOT = dirname(@__DIR__)

# The fixture's rows are a sample, so a row's parent may be absent
function fixture_db(path=":memory:")
    db = Store.open_db(path)
    SQLite.execute(db, "PRAGMA foreign_keys = OFF")
    for line in eachline(CITiming.FIXTURE)
        (isempty(line) || startswith(line, "--")) && continue
        SQLite.execute(db, line)
    end
    return db
end

body(r) = HTTP.header(r, "Content-Encoding") == "gzip" ? transcode(GzipDecompressor, r.body) : r.body

@testset "CITiming" begin

@testset "API routes" begin
    s = CITiming.fixture_server()
    notes = ["/api/notes/$n" for n in ("ttfx_annotations", "runtime_annotations", "sysimage_annotations", "methodology_changes")]
    targets = vcat(CITiming.landing_targets(), CITiming.withdb(CITiming.other_targets, s), notes, ["/api/status"])
    for target in vcat(targets, ["/api/", "/healthz"])
        r = CITiming.handle(s, HTTP.Request("GET", target, ["Accept-Encoding" => "gzip"]))
        @test r.status < 500 || error("$target: $(r.status)")
        r.status == 200 && @test JSON3.read(body(r)) !== nothing
    end
    @test CITiming.handle(s, HTTP.Request("GET", "/api/no/such/route")).status == 404
    # Not warmed up, so not ready
    @test CITiming.handle(s, HTTP.Request("GET", "/api/ready")).status == 503
    # A new route needs an example request among the server's own warm-up
    # targets. The run page's route reads Buildkite live, so it has none.
    seen = Set(CITiming.find_route(CITiming.split_target(t)[2])[1].path for t in targets)
    for route in CITiming.ROUTES
        route.path in ("ready", "runtime/run/<pipeline>/<build>/<job_id>") && continue
        @test route.path in seen || error("no example request of api/$(route.path)")
    end
end

@testset "export" begin
    mktempdir() do dir
        dbfile = joinpath(dir, "fixture.sqlite")
        close(fixture_db(dbfile))
        out = joinpath(dir, "out")
        cmd = `$(Base.julia_cmd()) --project=$ROOT $(joinpath(ROOT, "db", "export.jl")) --db $dbfile --out $out --force`
        @test success(pipeline(cmd; stdout=stderr, stderr=stderr))
        @test isfile(joinpath(out, "ttfx_summary.json.gz"))
    end
end

# Loading a script catches syntax errors and names undefined at top level;
# their entry points only run when started as a program
@testset "scripts load" begin
    scripts = vcat(filter(f -> startswith(f, "fetch_") && endswith(f, ".jl"), readdir(ROOT)),
                   joinpath.("analysis", filter(endswith(".jl"), readdir(joinpath(ROOT, "analysis")))),
                   joinpath.("tools", filter(endswith(".jl"), readdir(joinpath(ROOT, "tools")))),
                   joinpath.("db", filter(endswith(".jl"), readdir(joinpath(ROOT, "db")))))
    for f in scripts
        path = joinpath(ROOT, f)
        ex = Meta.parseall(read(path, String); filename=path)
        bad = findfirst(e -> e isa Expr && e.head in (:error, :incomplete), ex.args)
        @test bad === nothing || error("$f does not parse: $(ex.args[bad])")
    end
    for f in filter(f -> startswith(f, "fetch_") && endswith(f, ".jl"), readdir(ROOT))
        m = Module(Symbol(f))
        Core.eval(m, :(include(x) = Base.include($m, x)))
        @test (Base.include(m, joinpath(ROOT, f)); true)
    end
end

@testset "Datasette metadata" begin
    db = fixture_db()
    meta = JSON3.read(read(joinpath(ROOT, "db", "datasette-metadata.json"), String))
    dbmeta = first(values(meta.databases))
    for (table, t) in pairs(dbmeta.tables)
        cols = Set(String(r.name) for r in Store.query(db, "SELECT name FROM pragma_table_info(?)", (String(table),)))
        @test !isempty(cols) || error("metadata describes table $table, which the schema lacks")
        for c in keys(get(t, :columns, Dict()))
            @test String(c) in cols || error("metadata describes $table.$c, which the schema lacks")
        end
    end
    for (name, q) in pairs(dbmeta.queries)
        # Named parameters bind to NULL, which is enough to plan the query
        sql = replace(String(q.sql), r":\w+" => "NULL")
        @test (Store.query(db, "EXPLAIN " * sql); true)
    end
    close(db)
end

@testset "hand-written notes" begin
    for f in ("ttfx_annotations", "sysimage_annotations", "runtime_annotations")
        notes = JSON3.read(read(joinpath(ROOT, "data", "$f.json"), String))
        @test notes.schema_version == 1
        for a in notes.annotations
            @test haskey(a, :label) && haskey(a, :description)
        end
    end
    @test JSON3.read(read(joinpath(ROOT, "data", "methodology_changes.json"), String)) !== nothing
    @test JSON3.read(read(joinpath(ROOT, "site.webmanifest"), String)) !== nothing
end

end
