"""
Store: the SQLite database behind the site.

    include("db/Store.jl"); using .Store
    db = Store.open_db("ci-timing.sqlite")

Applies `schema.sql` on open (every statement is `IF NOT EXISTS`), and
provides the pieces the importer, exporter and fetchers share: the
change-sequence counter, content-aware upserts, id lookups for the
dimension tables, per-source run records and the timestamp formats.
"""
module Store

using SQLite, DBInterface, Dates, JSON3, CodecZstd, Statistics

export open_db, db_path, transaction, query, next_seq!, upsert_stmt, upsert!, getid!,
       source_run, compress_zst, decompress_zst,
       iso_now, legacy_minute_to_iso, iso_to_legacy_minute, TIMING_SOURCE

const SCHEMA_FILE = joinpath(@__DIR__, "schema.sql")
const DEFAULT_PATH = joinpath(dirname(@__DIR__), "ci-timing.sqlite")

const TIMING_SOURCE = "timing"

"""
    open_db(path=DEFAULT_PATH; create=true)

Open (and create, unless `create=false`) the database, in WAL mode with the
schema applied. Fetchers pass `create=false`: a missing file means the
seeded history is absent and they must not start from nothing.
"""
function open_db(path::AbstractString=DEFAULT_PATH; create::Bool=true)
    if !create && !isfile(path)
        error("database $path does not exist; run db/import_legacy.jl first or pass --bootstrap")
    end
    db = SQLite.DB(path)
    # SQLite.execute (not DBInterface.execute) closes its statement at once.
    # A DBInterface query stays "in progress" until its rows are consumed,
    # and an unconsumed PRAGMA counts as an active write statement, which
    # makes the next SAVEPOINT fail.
    SQLite.execute(db, "PRAGMA journal_mode = WAL")
    SQLite.execute(db, "PRAGMA synchronous = NORMAL")
    SQLite.execute(db, "PRAGMA foreign_keys = ON")
    apply_schema!(db)
    return db
end

"""
    query(db, sql, params=()) -> Vector{NamedTuple}

Run a SELECT and materialize every row, which also resets the statement.
Use this rather than `first`/`iterate` on a `DBInterface.execute` result.
"""
query(db::SQLite.DB, sql::AbstractString, params=()) = SQLite.Tables.rowtable(DBInterface.execute(db, sql, params))

"""
    db_path(args=ARGS) -> String

`--db PATH` from the arguments, else `CI_TIMING_DB` from the environment,
else `DEFAULT_PATH`. Every fetcher and CLI resolves the database this way.
"""
function db_path(args=ARGS)
    i = findfirst(==("--db"), args)
    i === nothing || return String(args[i+1])
    return get(ENV, "CI_TIMING_DB", DEFAULT_PATH)
end

function apply_schema!(db::SQLite.DB)
    sql = read(SCHEMA_FILE, String)
    # Strip comments (some hold semicolons), then split on statement
    # terminators. No string literal in the schema contains "--" or ";".
    body = replace(sql, r"--[^\n]*" => "")
    for stmt in split(body, ';')
        s = strip(stmt)
        isempty(s) && continue
        SQLite.execute(db, s)
    end
end

transaction(f, db::SQLite.DB) = SQLite.transaction(f, db)

meta(db, key) = query(db, "SELECT value FROM meta WHERE key = ?", (key,))[1].value
setmeta!(db, key, value) = DBInterface.execute(db, "INSERT OR REPLACE INTO meta VALUES (?, ?)", (key, string(value)))

"""
    next_seq!(db) -> Int

Advance and return the change sequence. Call once per write transaction
and stamp every row that transaction changes with the value.
"""
function next_seq!(db::SQLite.DB)
    seq = parse(Int, meta(db, "change_seq")) + 1
    setmeta!(db, "change_seq", seq)
    return seq
end

current_seq(db::SQLite.DB) = parse(Int, meta(db, "change_seq"))

"""
    upsert_stmt(db, table, keys, cols; seq=true)

Prepared INSERT ... ON CONFLICT DO UPDATE for `table`, keyed on `keys`.
Bind values in the order `keys..., cols...` (and `change_seq` last when
`seq=true`). The update only fires when a value column differs, so an
unchanged row is neither rewritten nor given a new change_seq.
"""
function upsert_stmt(db::SQLite.DB, table::AbstractString, keys, cols; seq::Bool=true)
    allcols = seq ? [keys..., cols..., "change_seq"] : [keys..., cols...]
    placeholders = join(fill("?", length(allcols)), ", ")
    sets = ["$c = excluded.$c" for c in cols]
    seq && push!(sets, "change_seq = excluded.change_seq")
    changed = join(["$table.$c IS NOT excluded.$c" for c in cols], " OR ")
    sql = "INSERT INTO $table ($(join(allcols, ", "))) VALUES ($placeholders) " *
          "ON CONFLICT ($(join(keys, ", "))) DO UPDATE SET $(join(sets, ", "))"
    isempty(cols) || (sql *= " WHERE $changed")
    return DBInterface.prepare(db, sql)
end

upsert!(stmt, values) = DBInterface.execute(stmt, values)

"""
    getid!(cache, db, table, keycols => keyvals) -> Int

Id of the dimension row (`bench_names`, `packages`, `dl_package_uuids`,
`job_kinds`), inserting it if new. `cache` is a Dict the caller keeps for the
duration of a run.
"""
function getid!(cache::Dict, db::SQLite.DB, table::AbstractString, keycols, keyvals)
    k = Tuple(keyvals)
    id = get(cache, k, nothing)
    id === nothing || return id
    where = join(["$c = ?" for c in keycols], " AND ")
    r = query(db, "SELECT id FROM $table WHERE $where", k)
    if isempty(r)
        DBInterface.execute(db, "INSERT INTO $table ($(join(keycols, ", "))) VALUES ($(join(fill("?", length(keycols)), ", ")))", k)
        id = Int(SQLite.last_insert_rowid(db))
    else
        id = Int(r[1].id)
    end
    cache[k] = id
    return id
end

"""
    source_run(f, db, source) -> f's return value

Record a fetcher run in `source_runs`: start, then success with
`rows_written` (what `f` returns as an Int, or 0) or failure with the error
message. The error is rethrown after recording.
"""
function source_run(f, db::SQLite.DB, source::AbstractString)
    DBInterface.execute(db, "INSERT INTO source_runs (source, started_at) VALUES (?, ?)", (source, iso_now()))
    id = SQLite.last_insert_rowid(db)
    try
        n = f()
        rows = n isa Integer ? Int(n) : 0
        DBInterface.execute(db, "UPDATE source_runs SET finished_at = ?, ok = 1, rows_written = ? WHERE id = ?",
                            (iso_now(), rows, id))
        return n
    catch err
        msg = sprint(showerror, err)
        DBInterface.execute(db, "UPDATE source_runs SET finished_at = ?, ok = 0, error = ? WHERE id = ?",
                            (iso_now(), first(msg, 2000), id))
        rethrow()
    end
end

compress_zst(bytes::AbstractVector{UInt8}) = transcode(ZstdCompressor, Vector{UInt8}(bytes))
compress_zst(s::AbstractString) = compress_zst(codeunits(s))
decompress_zst(bytes) = String(transcode(ZstdDecompressor, Vector{UInt8}(bytes)))

# --- timestamps -----------------------------------------------------------

const ISO_SECONDS = dateformat"yyyy-mm-ddTHH:MM:SSZ"
const LEGACY_MINUTE = dateformat"yyyy-mm-dd HH:MM"

iso_now() = Dates.format(now(UTC), ISO_SECONDS)
iso(dt::DateTime) = Dates.format(dt, ISO_SECONDS)

"Legacy `yyyy-mm-dd HH:MM` (UTC) to `yyyy-mm-ddTHH:MM:00Z`."
legacy_minute_to_iso(s::AbstractString) = iso(DateTime(s, LEGACY_MINUTE))

"`yyyy-mm-ddTHH:MM:SSZ` back to the legacy `yyyy-mm-dd HH:MM`."
iso_to_legacy_minute(s::AbstractString) = Dates.format(DateTime(s, ISO_SECONDS), LEGACY_MINUTE)

"""
    parse_upstream(s) -> DateTime

Parse the timestamp forms the upstream APIs use (`2026-09-20T13:51:01Z`,
`2026-09-20T13:51:01.123Z`, `2026-09-20T13:51:01+00:00`) as UTC.
"""
function parse_upstream(s::AbstractString)
    t = String(s)
    t = replace(t, r"\.\d+" => "")          # fractional seconds
    t = replace(t, r"(Z|[+-]00:?00)$" => "")
    return DateTime(t, dateformat"yyyy-mm-ddTHH:MM:SS")
end

end # module
