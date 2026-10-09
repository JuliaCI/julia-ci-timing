#!/usr/bin/env julia
# Measure the size of the binary distribution of every julia-ci master build, and of the
# latest julia-pr build of every open pull request.
#
# The build job of every build uploads the tarball as an artifact, and a master build
# also uploads it to the nightlies bucket as
# bin/linux/x86_64/<major.minor>/julia-<sha10>-linux-x86_64.tar.gz once the whole build
# has finished; the bucket keeps it for about 60 days. For each master build in the
# `builds` table (fetch_timing.jl) with no measurement yet, this downloads the tarball
# (from the bucket, else the artifact), unpacks it and records what
# tools/measure_sizes.jl measures: sizes of the sysimage and runtime libraries by ELF
# section, of the stdlib pkgimages and of each directory (size_metrics), every file of at
# least 1 MiB (size_files) and the tarball itself (the `tarball` metric). The history
# before the bucket's window comes from db/import_sizes.jl.
#
# For each open pull request whose newest julia-pr build is not measured yet, this
# measures that build's artifact as source `pr` and keeps one row in size_prs: the pull
# request, its build, and its merge-base with master, measured as a master commit too
# (from its julia-ci build, which has the artifact long before the bucket has it) and
# compared with only once it is. The list of open pull requests (titles,
# authors) comes from GitHub every PULLS_REFRESH and is kept in size_open_prs; GitHub also
# gives each new build's merge-base. Anonymously, which the host is, that stays well
# within the hourly quota fetch_ttfx.jl shares.

using HTTP
using JSON3
using CodecZlib
using Tar
using Dates

include(joinpath(@__DIR__, "db", "Store.jl"))
using .Store
using SQLite, DBInterface

include(joinpath(@__DIR__, "tools", "measure_sizes.jl"))
using .SizeMeasure

const BUCKET = "https://julialangnightlies-s3.julialang.org"
const TRIPLET = "x86_64-linux-gnu"
const BUCKET_DIR = "bin/linux/x86_64"
const TARBALL = r"/julia-([0-9a-f]{10})-linux-x86_64\.tar\.gz$"
# Builds older than the bucket keeps tarballs for are not looked for
const LOOKBACK_DAYS = 60
# Each tarball is about 350 MB and takes most of a minute; a run measures the newest
# master builds and pull requests for this long each and leaves the rest to the next run
const TIME_BUDGET = Minute(5)

const BUILDKITE_ORG = "julialang"
const API_BASE = "https://api.buildkite.com/v2"
const CI_PIPELINE = "julia-ci"
const PR_PIPELINE = "julia-pr"
const BUILD_JOB = ":linux: build x86_64-linux-gnu"
const JOB_TARBALL = r"^julia-[0-9a-f]+-linux-x86_64\.tar\.gz$"
# How far back julia-pr builds are listed: a pull request without a build since then is
# not measured
const PR_LOOKBACK_DAYS = 14
const PULLS_REFRESH = Hour(2)
const GITHUB_REPO = "https://api.github.com/repos/JuliaLang/julia"

function get_token()
    # An empty variable (the host exports one when the parameter is unset)
    # counts as unset
    token = strip(get(ENV, "BUILDKITE_API_TOKEN", ""))
    if isempty(token)
        token_file = joinpath(homedir(), ".buildkite_token")
        isfile(token_file) && (token = strip(read(token_file, String)))
    end
    isempty(token) && error("Set BUILDKITE_API_TOKEN env var or create ~/.buildkite_token")
    return token
end

# GET with retries on connection errors, 429 and 5xx, honouring Retry-After
# when the server sends one. HTTP.jl's own retry layer never sees a status
# code once status_exception is off, so this loop covers those.
function http_get_retry(url, headers=Pair{String,String}[]; attempts=4, read_idle_timeout=120, connect_timeout=30, kwargs...)
    local resp
    for attempt in 1:attempts
        resp = try
            HTTP.get(url, headers; status_exception=false, retry=false, read_idle_timeout, connect_timeout, kwargs...)
        catch e
            attempt == attempts && rethrow()
            @warn "Request failed, retrying" url attempt error=e
            sleep(2.0^attempt)
            continue
        end
        (resp.status == 429 || resp.status >= 500) || return resp
        attempt == attempts && return resp
        wait = something(tryparse(Int, HTTP.header(resp, "Retry-After")), 2^attempt)
        @warn "Retrying after HTTP $(resp.status)" url wait attempt
        sleep(wait)
    end
    return resp
end

function api_get(endpoint; token=get_token(), params=Dict())
    url = "$API_BASE/$endpoint"
    isempty(params) || (url *= "?" * join(["$k=$v" for (k, v) in params], "&"))
    resp = http_get_retry(url, ["Authorization" => "Bearer $token"])
    if resp.status != 200
        @warn "API request failed" url resp.status
        return nothing
    end
    return JSON3.read(resp.body)
end

# The host passes no token: anonymous, GitHub allows an address 60 requests an hour
function github_get(path)
    headers = ["User-Agent" => "julia-ci-timing-fetcher", "Accept" => "application/vnd.github+json"]
    token = get(ENV, "GITHUB_TOKEN", "")
    isempty(token) || push!(headers, "Authorization" => "Bearer $token")
    resp = http_get_retry("$GITHUB_REPO/$path", headers)
    if resp.status != 200
        @warn "GitHub request failed" path resp.status
        return nothing
    end
    return JSON3.read(resp.body)
end

# Keys of the newest two version directories (the master one and, right after a
# branch, the one before), as sha10 => key. ListObjectsV2, 1000 keys a page.
function bucket_tarballs()
    function list(params)
        out = String[]
        token = ""
        while true
            q = isempty(token) ? params : merge(params, Dict("continuation-token" => token))
            resp = HTTP.get(BUCKET * "/"; query=q, retry=true, read_idle_timeout=60)
            body = String(resp.body)
            append!(out, [m.captures[1] for m in eachmatch(r"<(?:Key|Prefix)>([^<]*)</(?:Key|Prefix)>", body)])
            m = match(r"<NextContinuationToken>([^<]*)<", body)
            m === nothing && return out
            token = HTTP.unescapeuri(m.captures[1])
        end
    end
    dirs = list(Dict("list-type" => "2", "prefix" => BUCKET_DIR * "/", "delimiter" => "/"))
    versions = sort!([VersionNumber(m.captures[1]) for d in dirs
                      for m in (match(r"/(\d+\.\d+)/$", d),) if m !== nothing])
    keys = Dict{String,String}()
    for v in versions[max(1, end - 1):end]
        for key in list(Dict("list-type" => "2", "prefix" => "$BUCKET_DIR/$(v.major).$(v.minor)/julia-"))
            m = match(TARBALL, key)
            m === nothing || (keys[m.captures[1]] = key)
        end
    end
    return keys
end

# Download a tarball with `download(io)`, unpack and measure it: (version, metrics, files)
function measure_tarball(download)
    mktempdir() do dir
        tgz = joinpath(dir, "julia.tar.gz")
        open(download, tgz, "w")
        root = joinpath(dir, "julia")
        open(tgz) do io
            Tar.extract(GzipDecompressorStream(io), root)
        end
        # The tarball holds one directory, julia-<sha10>
        tops = readdir(root; join=true)
        length(tops) == 1 && isdir(tops[1]) && (root = tops[1])
        metrics, files = SizeMeasure.measure(root)
        metrics["tarball"] = filesize(tgz)
        return SizeMeasure.version(root), metrics, files
    end
end

const BUILD_COLS = ["merged_at", "version", "build", "message", "measured_at"]

"""
    write_measurement!(db, source, triplet, commit, build_row, metrics, files; seq)

Replace the measurement of one commit: its `size_builds` row (`build_row` holds the
`BUILD_COLS`) and its `size_metrics` and `size_files` rows.
"""
function write_measurement!(db, source, triplet, commit, build_row, metrics, files; seq)
    key = (source, triplet, commit)
    upsert!(upsert_stmt(db, "size_builds", ["source", "triplet", "commit_sha"], BUILD_COLS),
            (key..., (build_row[Symbol(c)] for c in BUILD_COLS)..., seq))
    id = query(db, "SELECT id FROM size_builds WHERE source = ? AND triplet = ? AND commit_sha = ?", key)[1].id
    DBInterface.execute(db, "DELETE FROM size_metrics WHERE size_build_id = ?", (id,))
    DBInterface.execute(db, "DELETE FROM size_files WHERE size_build_id = ?", (id,))
    stmt = DBInterface.prepare(db, "INSERT INTO size_metrics VALUES (?, ?, ?)")
    for (metric, value) in metrics
        DBInterface.execute(stmt, (id, metric, value))
    end
    stmt = DBInterface.prepare(db, "INSERT INTO size_files VALUES (?, ?, ?)")
    for (path, bytes) in files
        DBInterface.execute(stmt, (id, path, bytes))
    end
end

bucket_download(key) = io -> HTTP.get("$BUCKET/$key"; response_stream=io, retry=true, read_idle_timeout=120)

# The artifact download endpoint answers with a redirect to a signed storage URL; follow
# it by hand so the API token is not sent along to the storage host
function artifact_download(url; token=get_token())
    return function (io)
        resp = http_get_retry(url, ["Authorization" => "Bearer $token"]; redirect=false)
        resp.status in (301, 302, 303, 307, 308) || error("artifact download failed: HTTP $(resp.status)")
        HTTP.get(HTTP.header(resp, "Location"); response_stream=io, retry=true, read_idle_timeout=120)
    end
end

# The download URL of the tarball the build job uploaded, or nothing
function job_tarball_url(pipeline, number, job_id)
    artifacts = api_get("organizations/$BUILDKITE_ORG/pipelines/$pipeline/builds/$number/jobs/$job_id/artifacts")
    artifacts === nothing && return nothing
    i = findfirst(a -> occursin(JOB_TARBALL, String(a.filename)), collect(artifacts))
    return i === nothing ? nothing : String(artifacts[i].download_url)
end

build_job(build) = (i = findfirst(j -> get(j, :name, nothing) == BUILD_JOB && get(j, :state, nothing) == "passed",
                                  collect(get(build, :jobs, []))); i === nothing ? nothing : build.jobs[i])

# Measure master commit `commit` from the bucket, or from the build job of its julia-ci
# build `build` (number, created_at, message; looked up when nothing) while the bucket
# does not have it yet or at all. Whether it was measured: false while that job has not
# finished.
function measure_master_commit!(db, commit, bucket; build=nothing)
    if build === nothing
        r = query(db, "SELECT number, created_at, message FROM builds WHERE pipeline = 'julia-ci' AND commit_sha = ? " *
                      "ORDER BY number LIMIT 1", (commit,))
        if isempty(r)
            bs = api_get("organizations/$BUILDKITE_ORG/pipelines/$CI_PIPELINE/builds"; params=Dict("commit" => commit, "branch" => "master", "per_page" => 5))
            (bs === nothing || isempty(bs)) && return false
            b = bs[end]   # the first build of the commit
            build = (number=Int(b.number), created_at=Store.iso(Store.parse_upstream(String(b.created_at))),
                     message=first(split(String(something(get(b, :message, ""), "")), '\n')))
        else
            build = (number=Int(r[1].number), created_at=String(r[1].created_at), message=String(r[1].message))
        end
    end
    key = get(bucket, first(commit, 10), nothing)
    download = if key !== nothing
        bucket_download(key)
    else
        b = api_get("organizations/$BUILDKITE_ORG/pipelines/$CI_PIPELINE/builds/$(build.number)")
        job = b === nothing ? nothing : build_job(b)
        url = job === nothing ? nothing : job_tarball_url(CI_PIPELINE, build.number, job.id)
        url === nothing && return false
        artifact_download(url)
    end
    version, metrics, files = measure_tarball(download)
    # The artifact is the same tarball the bucket gets
    message = build.message == "Scheduled build" ? "" : build.message
    row = (merged_at=build.created_at, version, build=build.number, message, measured_at=iso_now())
    transaction(db) do
        write_measurement!(db, "ci", TRIPLET, commit, row, metrics, files; seq=next_seq!(db))
    end
    @info "Measured" commit build=build.number from=key === nothing ? "artifact" : "bucket" total=metrics["total"] sysimg=metrics["sysimg"]
    return true
end

function measure_master!(db, bucket; deadline)
    since = Store.iso(now(UTC) - Day(LOOKBACK_DAYS))
    # The first build of each commit, finished or not: its build job may be done. A
    # scheduled build's message is not the commit's subject.
    pending = query(db, """
        SELECT b.commit_sha, min(b.number) AS build, min(b.created_at) AS created_at,
               max(CASE WHEN b.message != 'Scheduled build' THEN b.message ELSE '' END) AS message
        FROM builds b
        WHERE b.pipeline = 'julia-ci' AND b.branch = 'master' AND b.commit_sha IS NOT NULL AND b.created_at >= ?
          AND NOT EXISTS (SELECT 1 FROM size_builds s
                          WHERE s.source = 'ci' AND s.triplet = ? AND s.commit_sha = b.commit_sha)
        GROUP BY b.commit_sha
        ORDER BY created_at DESC""", (since, TRIPLET))
    @info "Master builds without a size measurement" pending=length(pending)
    n = 0
    for r in pending
        now(UTC) > deadline && break
        commit = String(r.commit_sha)
        try
            build = (number=Int(r.build), created_at=String(r.created_at), message=String(r.message))
            measure_master_commit!(db, commit, bucket; build) && (n += 1)
        catch e
            @error "Measuring failed" commit exception=(e, catch_backtrace())
        end
    end
    return n
end

# --- pull requests -------------------------------------------------------------

const PR_COLS = ["title", "author", "draft", "base_ref", "build", "build_created_at", "web_url", "head_commit",
                 "merge_base", "base_commit"]

# The newest julia-pr build since `since` of each pull request whose linux-x86_64
# build job passed, as pull request number => (build, job)
function pr_builds(since)
    out = Dict{Int,Any}()
    for page in 1:50
        params = Dict("created_from" => Store.iso(since), "per_page" => 100, "page" => page)
        builds = api_get("organizations/$BUILDKITE_ORG/pipelines/$PR_PIPELINE/builds"; params)
        builds === nothing && error("listing $PR_PIPELINE builds failed (page $page)")
        isempty(builds) && break
        for build in builds
            pr = get(build, :pull_request, nothing)
            n = pr === nothing ? nothing : tryparse(Int, string(get(pr, :id, "")))
            n === nothing && continue
            haskey(out, n) && out[n][1].number > build.number && continue
            job = build_job(build)
            job === nothing || (out[n] = (build, job))
        end
    end
    return out
end

# The merge-base of a pull request to compare it with, measured now if it is not yet;
# missing while its julia-ci build job has not finished
function pr_base(db, merge_base, bucket)
    measured() = !isempty(query(db, "SELECT 1 FROM size_builds WHERE source = 'ci' AND triplet = ? AND commit_sha = ?",
                                (TRIPLET, merge_base)))
    measured() && return merge_base
    try
        measure_master_commit!(db, merge_base, bucket)
    catch e
        @error "Measuring the merge-base failed" merge_base exception=(e, catch_backtrace())
    end
    return measured() ? merge_base : missing
end

function measure_pr!(db, n, pull, build, job, bucket)
    head = String(build.commit)
    url = job_tarball_url(PR_PIPELINE, build.number, job.id)
    if url === nothing
        @warn "No tarball among the build job's artifacts" pr=n build=build.number
        return false
    end
    cmp = github_get("compare/master...$head")
    cmp === nothing && return false
    merge_base = String(cmp.merge_base_commit.sha)
    version, metrics, files = measure_tarball(artifact_download(url))
    # Compressed differently from the master builds' tarballs, so not compared
    delete!(metrics, "tarball")
    base = pr_base(db, merge_base, bucket)
    created_at = Store.iso(Store.parse_upstream(String(build.created_at)))
    transaction(db) do
        seq = next_seq!(db)
        row = (merged_at=created_at, version, build=Int(build.number), message=pull.title, measured_at=iso_now())
        write_measurement!(db, "pr", TRIPLET, head, row, metrics, files; seq)
        upsert!(upsert_stmt(db, "size_prs", ["pr_number"], PR_COLS),
                (n, pull.title, pull.author, pull.draft, pull.base_ref, Int(build.number), created_at,
                 String(build.web_url), head, merge_base, base, seq))
    end
    @info "Measured pull request" pr=n build=build.number total=metrics["total"] merge_base measured_base=base !== missing
    return true
end

# The open pull requests as number => (title, author, draft, base_ref), from GitHub when
# the copy in size_open_prs is older than PULLS_REFRESH. A refresh also drops the rows
# of closed pull requests and brings the titles of the others up to date.
function open_prs!(db)
    cached() = Dict(Int(r.pr_number) => (title=String(r.title), author=String(r.author), draft=Int(r.draft), base_ref=String(r.base_ref))
                    for r in query(db, "SELECT * FROM size_open_prs"))
    at = query(db, "SELECT value FROM meta WHERE key = 'sizes:open_prs_at'")
    !isempty(at) && now(UTC) - Store.parse_upstream(String(at[1].value)) < PULLS_REFRESH && return cached()
    pulls = Dict{Int,Any}()
    for page in 1:50
        list = github_get("pulls?state=open&per_page=100&page=$page")
        # The old copy serves until the next run rather than dropping rows on a partial list
        list === nothing && return cached()
        isempty(list) && break
        for p in list
            u = get(p, :user, nothing)
            pulls[Int(p.number)] = (title=String(something(get(p, :title, ""), "")), author=u === nothing ? "" : String(u.login),
                                    draft=get(p, :draft, false) === true ? 1 : 0, base_ref=String(p.base.ref))
        end
    end
    transaction(db) do
        seq = next_seq!(db)
        DBInterface.execute(db, "DELETE FROM size_open_prs")
        stmt = DBInterface.prepare(db, "INSERT INTO size_open_prs VALUES (?, ?, ?, ?, ?)")
        for (n, p) in pulls
            DBInterface.execute(stmt, (n, p.title, p.author, p.draft, p.base_ref))
        end
        DBInterface.execute(db, "DELETE FROM size_prs WHERE pr_number NOT IN (SELECT pr_number FROM size_open_prs)")
        DBInterface.execute(db, "UPDATE size_prs SET title = o.title, author = o.author, draft = o.draft, base_ref = o.base_ref, change_seq = ? " *
                                "FROM size_open_prs o WHERE o.pr_number = size_prs.pr_number AND (size_prs.title IS NOT o.title " *
                                "OR size_prs.author IS NOT o.author OR size_prs.draft IS NOT o.draft OR size_prs.base_ref IS NOT o.base_ref)", (seq,))
        DBInterface.execute(db, "INSERT OR REPLACE INTO meta VALUES ('sizes:open_prs_at', ?)", (iso_now(),))
    end
    return pulls
end

# Drop the pull request measurements no size_prs row points to: superseded builds and
# closed pull requests
function prune_prs!(db)
    transaction(db) do
        stale = "SELECT id FROM size_builds WHERE source = 'pr' AND commit_sha NOT IN (SELECT head_commit FROM size_prs)"
        DBInterface.execute(db, "DELETE FROM size_metrics WHERE size_build_id IN ($stale)")
        DBInterface.execute(db, "DELETE FROM size_files WHERE size_build_id IN ($stale)")
        DBInterface.execute(db, "DELETE FROM size_builds WHERE id IN ($stale)")
    end
end

# Pull requests whose merge-base was not measured yet get it once its build job is done
function rebase_prs!(db, bucket; deadline)
    for r in query(db, "SELECT pr_number, merge_base FROM size_prs WHERE base_commit IS NULL AND merge_base != ''")
        now(UTC) > deadline && break
        base = pr_base(db, String(r.merge_base), bucket)
        base === missing && continue
        transaction(db) do
            DBInterface.execute(db, "UPDATE size_prs SET base_commit = ?, change_seq = ? WHERE pr_number = ?",
                                (base, next_seq!(db), Int(r.pr_number)))
        end
        @info "Merge-base measured" pr=r.pr_number base
    end
end

function measure_prs!(db, bucket; deadline)
    pulls = open_prs!(db)
    known = Dict(Int(r.pr_number) => Int(r.build) for r in query(db, "SELECT pr_number, build FROM size_prs"))
    todo = sort!([(n, b, j) for (n, (b, j)) in pr_builds(now(UTC) - Day(PR_LOOKBACK_DAYS))
                  if haskey(pulls, n) && b.number > get(known, n, 0)];
                 by=t -> -t[2].number)
    @info "Open pull requests with an unmeasured build" count=length(todo)
    n = 0
    for (pr, build, job) in todo
        now(UTC) > deadline && break
        try
            measure_pr!(db, pr, pulls[pr], build, job, bucket) && (n += 1)
        catch e
            @error "Measuring the pull request failed" pr build=build.number exception=(e, catch_backtrace())
        end
    end
    rebase_prs!(db, bucket; deadline)
    prune_prs!(db)
    return n
end

function run!(db)
    bucket = bucket_tarballs()
    n = measure_master!(db, bucket; deadline=now(UTC) + TIME_BUDGET)
    # A failing GitHub or julia-pr listing leaves the pull requests as they were rather
    # than failing the master measurements with it
    try
        n += measure_prs!(db, bucket; deadline=now(UTC) + TIME_BUDGET)
    catch e
        @error "Measuring pull requests failed" exception=(e, catch_backtrace())
    end
    return n
end

function main(args=ARGS)
    db = open_db(Store.db_path(args); create=false)
    source_run(db, "sizes") do
        run!(db)
    end
    close(db)
    return 0
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main())
end
