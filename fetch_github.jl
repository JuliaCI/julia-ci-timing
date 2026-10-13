#!/usr/bin/env julia
# Record the issues, pull requests and master commits of JuliaLang/julia, for the
# Activity tab: how many issues and pull requests are open over time, and how many
# are opened, closed and merged, and commits landed, per day.
#
# gh_items holds every issue and pull request as GitHub lists it now, one row each.
# The issues listing (which has the pull requests too) is walked in order of
# updated_at from the newest row already stored, so a run fetches what changed since
# the last one: a page or two. master commits go into the commits table, from the
# commits listing since the newest stored.
#
# The history before the first run comes from a seed: a dump of both tables
# (`--dump-seed DIR` writes one from a filled database) published as the assets of
# the github-seed release, which a run imports when its tables are empty and then
# catches up from. Without the seed the first run lists everything, about 1300
# requests, which needs GITHUB_TOKEN (anonymous requests get 60 an hour); later runs
# take a few and fit in the anonymous quota.
#
#   julia --project fetch_github.jl [--db PATH]
#   julia --project fetch_github.jl [--db PATH] --dump-seed DIR
#
# GITHUB_SEED_URL points the seed download elsewhere (a local copy, for testing).

using HTTP
using JSON3
using Dates
using CodecZlib

include(joinpath(@__DIR__, "db", "Store.jl"))
include(joinpath(@__DIR__, "db", "Fetch.jl"))
using .Store
using SQLite, DBInterface

const ITEM_COLS = ["kind", "title", "author", "labels", "created_at", "closed_at", "merged_at", "gh_updated_at"]
const COMMIT_COLS = ["author", "authored_at", "committed_at", "subject", "pr_number"]
# Commits can land with a committer date a little older than the newest stored one
const COMMIT_OVERLAP = Day(2)
const SEED_URL = get(ENV, "GITHUB_SEED_URL", "https://github.com/JuliaCI/julia-ci-timing/releases/download/github-seed")
const SEED_TABLES = ("gh_items" => ["number"; ITEM_COLS], "commits" => ["sha"; COMMIT_COLS])

# A page of a listing; throws when it failed, so a run never takes part of a
# listing for the whole
function github_get(url)
    resp = http_get_retry(url, github_headers())
    if resp.status in (403, 429) && HTTP.header(resp, "X-RateLimit-Remaining") == "0"
        error("GitHub's rate limit is spent until the hour turns; set GITHUB_TOKEN for a backfill")
    end
    resp.status == 200 || error("GET $url failed: HTTP $(resp.status): $(first(String(resp.body), 500))")
    return resp
end

at(x) = x === nothing ? missing : Store.iso(Store.parse_upstream(String(x)))
str(x) = x === nothing ? missing : String(x)

function item_row(it)
    pr = get(it, :pull_request, nothing)
    labels = join((String(l.name) for l in something(get(it, :labels, nothing), [])), ",")
    user = get(it, :user, nothing)
    return (Int(it.number), pr === nothing ? "issue" : "pr", String(something(it.title, "")),
            user === nothing ? missing : str(user.login), labels, at(it.created_at), at(get(it, :closed_at, nothing)),
            pr === nothing ? missing : at(get(pr, :merged_at, nothing)), at(it.updated_at))
end

# Walk the issues listing by updated_at, from the newest stored row. Each page is
# committed on its own, so an interrupted backfill resumes where it stopped.
function update_items!(db)
    r = query(db, "SELECT max(gh_updated_at) AS t FROM gh_items")
    # An earlier since (1970) lists nothing
    since = r[1].t === missing ? "2009-01-01T00:00:00Z" : String(r[1].t)
    stmt = upsert_stmt(db, "gh_items", ["number"], ITEM_COLS)
    page, n = 1, 0
    while true
        resp = github_get("$GITHUB_REPO/issues?state=all&sort=updated&direction=asc&per_page=100&page=$page&since=$since")
        items = JSON3.read(resp.body)
        isempty(items) && break
        transaction(db) do
            seq = next_seq!(db)
            for it in items
                upsert!(stmt, (item_row(it)..., seq))
            end
        end
        n += length(items)
        length(items) < 100 && break
        last = at(items[end].updated_at)
        # Many rows updated in the same second would keep `since` in place
        if last == since
            page += 1
        else
            since, page = last, 1
        end
        n % 5000 < 100 && @info "Issues and pull requests" fetched=n through=since
    end
    return n
end

pr_number(subject) = (m = match(r"\(#(\d+)\)\s*$", subject); m === nothing ? missing : parse(Int, m.captures[1]))

function update_commits!(db)
    # Until a full listing has finished, newest first, the newest stored commit
    # says nothing about the older ones
    done = !isempty(query(db, "SELECT 1 FROM meta WHERE key = 'github_commits_backfilled'"))
    r = query(db, "SELECT max(committed_at) AS t FROM commits")
    url = "$GITHUB_REPO/commits?sha=master&per_page=100"
    (done && r[1].t !== missing) && (url *= "&since=" * Store.iso(DateTime(String(r[1].t), Store.ISO_SECONDS) - COMMIT_OVERLAP))
    stmt = upsert_stmt(db, "commits", ["sha"], COMMIT_COLS; seq=false)
    n = 0
    while url !== nothing
        resp = github_get(url)
        list = JSON3.read(resp.body)
        transaction(db) do
            for c in list
                subject = String(first(split(String(c.commit.message), '\n')))
                author = get(c, :author, nothing)
                login = author === nothing ? str(c.commit.author.name) : str(author.login)
                upsert!(stmt, (String(c.sha), login, at(c.commit.author.date), at(c.commit.committer.date),
                               subject, pr_number(subject)))
            end
        end
        n += length(list)
        n >= 100 && n % 5000 < 100 && @info "Commits" fetched=n through=isempty(list) ? "" : at(list[end].commit.committer.date)
        url = next_link(HTTP.header(resp, "Link"))
    end
    done || transaction(() -> Store.setmeta!(db, "github_commits_backfilled", Store.iso_now()), db)
    return n
end

# --- seed ---------------------------------------------------------------------

# One gzipped file per table, a JSON array of the row's columns per line
seed_file(table) = "$table.ndjson.gz"

function dump_seed(db, dir)
    mkpath(dir)
    for (table, cols) in SEED_TABLES
        path = joinpath(dir, seed_file(table))
        rows = query(db, "SELECT $(join(cols, ", ")) FROM $table ORDER BY $(cols[1])")
        open(GzipCompressorStream, path, "w") do io
            for r in rows
                JSON3.write(io, [x === missing ? nothing : x for x in r])
                println(io)
            end
        end
        @info "Wrote seed" path rows=length(rows)
    end
end

# Import the seed into whichever table is empty; a seed that cannot be had leaves
# the run to list everything from the API
function import_seed!(db)
    n = 0
    for (table, cols) in SEED_TABLES
        isempty(query(db, "SELECT 1 FROM $table LIMIT 1")) || continue
        resp = try
            http_get_retry("$SEED_URL/$(seed_file(table))")
        catch e
            @warn "Seed download failed" table error=e
            continue
        end
        if resp.status != 200
            @warn "No seed" table status=resp.status
            continue
        end
        stmt = upsert_stmt(db, table, cols[1:1], cols[2:end]; seq=table == "gh_items")
        before = n
        transaction(db) do
            seq = next_seq!(db)
            for line in eachline(IOBuffer(transcode(GzipDecompressor, resp.body)))
                row = Any[x === nothing ? missing : x for x in JSON3.read(line)]
                table == "gh_items" && push!(row, seq)
                upsert!(stmt, Tuple(row))
                n += 1
            end
            # The seed is a whole listing, so the commits need no backfill
            table == "commits" && Store.setmeta!(db, "github_commits_backfilled", Store.iso_now())
        end
        @info "Imported seed" table rows=n-before
    end
    return n
end

function main(args=ARGS)
    db = open_db(Store.db_path(args); create=false)
    i = findfirst(==("--dump-seed"), args)
    if i !== nothing
        dump_seed(db, args[i+1])
        close(db)
        return 0
    end
    source_run(db, "github") do
        seeded = import_seed!(db)
        items = update_items!(db)
        commits = update_commits!(db)
        @info "GitHub activity recorded" seeded items commits
        seeded + items + commits
    end
    close(db)
    return 0
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
