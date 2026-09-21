#!/usr/bin/env julia
# The stage 1 gate of docs/database-migration.md: compare what two origins
# of the site serve under data/, the Pages build against the AWS host.
#
#   julia --project db/compare_origins.jl REFERENCE CANDIDATE [--settle-hours 48] [--max-age-hours 6] [--max-disk-pct 80]
#
# Each side is a base URL (files are read from URL/data/) or a directory
# holding the same files. The two origins fetch at different times and the
# database keeps history the files drop, so rows are matched by key rather
# than position, and the candidate has to carry every settled row of the
# reference with the same values: timing runs of builds below the
# fully-captured threshold of fetch_timing.jl, and benchmark, pkgeval,
# TTFX, coverage and download rows dated before --settle-hours ago. Newer
# rows, rows only on the candidate and derived fields (per-job stats, the
# TTFX task list, the download tag list) are counted, not failed. Every
# candidate file must have been generated within --max-age-hours; agents
# are checked for freshness only. A candidate URL's /healthz must report a
# disk below --max-disk-pct. Exit 1 on any failure.

using Pkg
Pkg.activate(dirname(@__DIR__); io=devnull)

using JSON3, CodecZlib, HTTP, Dates

include("compare.jl")   # load, compare!, Report, note!, MAX_REPORTS

const KEY_JOBS = [":linux: test x86_64-linux-gnu", ":linux: build x86_64-linux-gnu"]
const LOOKBACK = 50

# --- sides -------------------------------------------------------------------

struct Side
    base::String
    dir::String   # downloads land here; a directory base is read in place
end

# Local path of a file of the side, or nothing when the side does not have it
function file(side::Side, rel)
    if isdir(side.base)
        p = joinpath(side.base, rel)
        return isfile(p) ? p : nothing
    end
    dest = joinpath(side.dir, rel)
    isfile(dest) && return dest
    url = "$(rstrip(side.base, '/'))/data/$rel"
    r = HTTP.get(url; status_exception=false, readtimeout=120)
    r.status == 404 && return nothing
    r.status == 200 || error("GET $url: HTTP $(r.status)")
    mkpath(dirname(dest))
    write(dest, r.body)
    return dest
end

loadfile(side, rel) = (p = file(side, rel); p === nothing ? nothing : load(p))

# --- keyed comparison --------------------------------------------------------

mutable struct Tally
    settled::Int
    pending::Int
    pending_differ::Int
    extras::Int
end
Tally() = Tally(0, 0, 0, 0)

function copy_lines!(rep, sub; prefix="DIFF")
    for l in sub.lines
        length(rep.lines) < MAX_REPORTS || break
        push!(rep.lines, replace(l, r"^DIFF" => prefix))
    end
end

# Rows of the reference that `settled(row)` accepts must be on the candidate
# unchanged; the rest is tallied. Keys only on the candidate are extras.
function compare_keyed!(rep, tally, name, ref::Dict, cand::Dict, settled)
    for (k, a) in ref
        b = get(cand, k, nothing)
        if b === nothing
            settled(a) ? note!(rep, "$name[$k]", "missing from candidate") : (tally.pending += 1)
            continue
        end
        sub = Report()
        compare!(sub, a, b, "$name[$k]")
        if settled(a)
            if sub.diffs == 0
                tally.settled += 1
            else
                rep.diffs += sub.diffs
                copy_lines!(rep, sub)
            end
        else
            tally.pending += 1
            sub.diffs == 0 || (tally.pending_differ += 1)
        end
    end
    tally.extras += count(k -> !haskey(ref, k), keys(cand))
end

# Fields outside the keyed rows: differences are reported, never failed
function compare_rest!(rep, name, ref::Dict, cand::Dict, skip)
    sub = Report()
    for k in union(keys(ref), keys(cand))
        (k in skip || k == "generated_at") && continue
        if !haskey(cand, k)
            note!(sub, "$name.$k", "missing from candidate")
        elseif !haskey(ref, k)
            note!(sub, "$name.$k", "only on candidate")
        else
            compare!(sub, ref[k], cand[k], "$name.$k")
        end
    end
    copy_lines!(rep, sub; prefix="pending")
end

# --- settledness -------------------------------------------------------------

# The date of a row (yyyy-mm-dd, with any time after it) is settled when it
# is older than the cutoff; an unknown date is not
function dated_before(cutoff::Date)
    return function (row)
        d = row isa Dict ? get(row, "date", nothing) : nothing
        d isa AbstractString && length(d) >= 10 || return false
        return Date(d[1:10]) < cutoff
    end
end

# Builds below this number per pipeline are fully captured: the rule of
# fetch_timing.jl applied to the exported order (newest first)
function captured_threshold(jobs)
    thr = Dict{String,Int}()
    for name in KEY_JOBS
        haskey(jobs, name) || continue
        seen = Dict{String,Int}()
        for r in jobs[name]["recent"]
            p = r["pipeline"]
            seen[p] = get(seen, p, 0) + 1
            seen[p] <= LOOKBACK || continue
            thr[p] = min(get(thr, p, typemax(Int)), Int(r["build"]))
        end
    end
    return thr
end

# --- per-file views ----------------------------------------------------------

function timing_rows(jobs)
    rows = Dict{String,Any}()
    for (name, j) in jobs, r in j["recent"]
        rows["$(r["pipeline"])#$(r["build"]) $name/$(r["retry"])"] = r
    end
    return rows
end

# Benchmark group files are columnar per statistic; one row per report
function group_rows(d)
    rows = Dict{String,Any}()
    for (stat, cols) in d
        paths = cols["date_paths"]
        for i in eachindex(paths)
            rows["$stat/$(paths[i])"] = Dict{String,Any}(
                "date" => cols["dates"][i], "commit" => cols["commits"][i],
                "benchmarks" => Dict{String,Any}(n => get(v, i, nothing) for (n, v) in cols["benchmarks"]))
        end
    end
    return rows
end

bykey(rows, key) = Dict{String,Any}(string(r[key]) => r for r in rows)

hours_since(s) = (now(UTC) - DateTime(s[1:19], dateformat"yyyy-mm-ddTHH:MM:SS")) / Hour(1)

# --- the gate ----------------------------------------------------------------

mutable struct Gate
    ref::Side
    cand::Side
    cutoff::Date
    max_age::Float64
    max_disk::Float64
    failed::Int
end

function report!(gate, name, rep, tally, freshness)
    parts = String[]
    tally === nothing || push!(parts, "settled $(tally.settled), pending $(tally.pending)" *
        (tally.pending_differ > 0 ? " ($(tally.pending_differ) differ)" : "") * ", candidate extras $(tally.extras)")
    freshness === nothing || push!(parts, freshness)
    status = rep.diffs == 0 ? "ok" : "FAIL ($(rep.diffs) differences)"
    println(rpad(name, 45), status, isempty(parts) ? "" : "    " * join(parts, "; "))
    foreach(l -> println("    ", l), rep.lines)
    rep.diffs == 0 || (gate.failed += 1)
end

# Both files loaded, or a failure recorded for a candidate that lacks one
function both(gate, name)
    a = loadfile(gate.ref, name)
    b = loadfile(gate.cand, name)
    if a === nothing || b === nothing
        rep = Report()
        b === nothing && note!(rep, name, "missing from candidate")
        a === nothing && push!(rep.lines, "info $name: not on reference")
        report!(gate, name, rep, nothing, nothing)
        return nothing
    end
    return a, b
end

# Candidate files must be fresh; the reference's age is shown for context
# (its legacy fetchers keep the old timestamp when nothing changed)
function freshness!(rep, gate, name, a, b)
    ra = hours_since(a["generated_at"])
    ca = hours_since(b["generated_at"])
    ca <= gate.max_age || note!(rep, name, "candidate generated $(round(ca; digits=1)) h ago")
    return "generated $(round(ra; digits=1)) h / $(round(ca; digits=1)) h ago"
end

function gate_timing!(gate)
    name = "timing_summary.json.gz"
    ab = both(gate, name)
    ab === nothing && return
    a, b = ab
    rep = Report()
    tally = Tally()
    # Settled on both sides only below both thresholds
    thr = merge(min, captured_threshold(a["jobs"]), captured_threshold(b["jobs"]))
    settled(r) = Int(r["build"]) < get(thr, r["pipeline"], 0)
    compare_keyed!(rep, tally, "jobs", timing_rows(a["jobs"]), timing_rows(b["jobs"]), settled)
    for j in setdiff(keys(a["jobs"]), keys(b["jobs"]))
        note!(rep, "jobs.$j", "missing from candidate")
    end
    compare_keyed!(rep, tally, "coverage", a["coverage"], b["coverage"], dated_before(gate.cutoff))
    fresh = freshness!(rep, gate, name, a, b)
    report!(gate, name, rep, tally, fresh * "; captured below " * join(("$p<$n" for (p, n) in sort(collect(thr))), " "))
end

function gate_reports!(gate, name, key, rest_skip)
    ab = both(gate, name)
    ab === nothing && return nothing
    a, b = ab
    rep = Report()
    tally = Tally()
    compare_keyed!(rep, tally, "reports", bykey(a["reports"], key), bykey(b["reports"], key), dated_before(gate.cutoff))
    compare_rest!(rep, name, a, b, rest_skip)
    report!(gate, name, rep, tally, freshness!(rep, gate, name, a, b))
    return a, b
end

function gate_benchmarks!(gate)
    ab = gate_reports!(gate, "benchmark_summary.json.gz", "date_path", ["reports"])
    ab === nothing && return
    a, b = ab
    groups = sort!(unique(String[g for s in (a, b) for r in s["reports"] for g in keys(r["by_group"])]))
    for g in groups
        name = "benchmarks/$g.json.gz"
        gab = both(gate, name)
        gab === nothing && continue
        rep = Report()
        tally = Tally()
        compare_keyed!(rep, tally, g, group_rows(gab[1]), group_rows(gab[2]), dated_before(gate.cutoff))
        report!(gate, name, rep, tally, nothing)
    end
end

function gate_ttfx!(gate)
    name = "ttfx_summary.json.gz"
    ab = both(gate, name)
    ab === nothing && return
    a, b = ab
    rep = Report()
    tally = Tally()
    compare_keyed!(rep, tally, "builds", bykey(a["builds"], "job_id"), bykey(b["builds"], "job_id"), dated_before(gate.cutoff))
    compare_rest!(rep, name, a, b, ["builds"])
    report!(gate, name, rep, tally, freshness!(rep, gate, name, a, b))
end

function gate_packages!(gate)
    name = "packages_downloads_summary.json.gz"
    ab = both(gate, name)
    ab === nothing && return
    a, b = ab
    rep = Report()
    tally = Tally()
    series = ["series", "version_mix", "version_stage_mix"]
    for s in series
        compare_keyed!(rep, tally, s, bykey(a[s], "date"), bykey(b[s], "date"), dated_before(gate.cutoff))
    end
    compare_rest!(rep, name, a, b, series)
    report!(gate, name, rep, tally, freshness!(rep, gate, name, a, b))
end

# Snapshots are taken at different moments, so only their age is checked
function gate_agents!(gate)
    name = "agents/latest.json"
    ab = both(gate, name)
    ab === nothing && return
    a, b = ab
    rep = Report()
    report!(gate, name, rep, nothing, freshness!(rep, gate, name, a, b))
    # The current month's history, or last month's during the first snapshots of a month
    month = Dates.format(now(UTC), dateformat"yyyy-mm")
    last_month = Dates.format(now(UTC) - Month(1), dateformat"yyyy-mm")
    rep = Report()
    rel = "agents/history-$month.ndjson"
    lines = loadfile(gate.cand, rel)
    if lines === nothing
        rel = "agents/history-$last_month.ndjson"
        lines = loadfile(gate.cand, rel)
    end
    if lines === nothing || isempty(lines)
        note!(rep, rel, "missing from candidate")
        report!(gate, rel, rep, nothing, nothing)
    else
        age = hours_since(lines[end]["time"])
        age <= gate.max_age || note!(rep, rel, "last candidate snapshot $(round(age; digits=1)) h ago")
        report!(gate, rel, rep, nothing, "$(length(lines)) snapshots, last $(round(age; digits=1)) h ago")
    end
end

# The host's own health report: the disk, and each source's last run
function gate_health!(gate)
    isdir(gate.cand.base) && return
    name = "healthz"
    rep = Report()
    r = HTTP.get("$(rstrip(gate.cand.base, '/'))/healthz"; status_exception=false, readtimeout=60)
    if r.status != 200
        note!(rep, name, "HTTP $(r.status)")
        report!(gate, name, rep, nothing, nothing)
        return
    end
    h = tojulia(JSON3.read(r.body))
    disk = get(h, "disk_used_pct", nothing)
    disk === nothing || disk <= gate.max_disk || note!(rep, name, "disk $(disk)% used")
    failing = [s for (s, v) in get(h, "sources", Dict()) if get(v, "last_ok", true) == false]
    isempty(failing) || push!(rep.lines, "info $name: last run failed for " * join(sort(failing), ", "))
    report!(gate, name, rep, nothing, "disk $(disk === nothing ? "?" : disk)% used")
end

function parse_args(args)
    opts = Dict{String,Any}("settle-hours" => 48.0, "max-age-hours" => 6.0, "max-disk-pct" => 80.0)
    positional = String[]
    i = 1
    while i <= length(args)
        if args[i] in ("--settle-hours", "--max-age-hours", "--max-disk-pct")
            opts[args[i][3:end]] = parse(Float64, args[i + 1])
            i += 2
        else
            push!(positional, args[i])
            i += 1
        end
    end
    length(positional) == 2 || error("usage: compare_origins.jl REFERENCE CANDIDATE [--settle-hours H] [--max-age-hours H] [--max-disk-pct P]")
    return positional, opts
end

function run_gate(args)
    (ref, cand), opts = parse_args(args)
    tmp = mktempdir()
    gate = Gate(Side(ref, joinpath(tmp, "reference")), Side(cand, joinpath(tmp, "candidate")),
                Date(now(UTC) - Hour(round(Int, opts["settle-hours"]))), opts["max-age-hours"], opts["max-disk-pct"], 0)
    println("reference $ref\ncandidate $cand\nsettled before $(gate.cutoff), candidate files at most $(gate.max_age) h old\n")
    gate_timing!(gate)
    gate_benchmarks!(gate)
    gate_reports!(gate, "pkgeval_summary.json.gz", "date_path", ["reports"])
    gate_ttfx!(gate)
    gate_packages!(gate)
    gate_agents!(gate)
    gate_health!(gate)
    println(gate.failed == 0 ? "\nPASS" : "\nFAIL: $(gate.failed) file(s)")
    exit(gate.failed == 0 ? 0 : 1)
end

abspath(PROGRAM_FILE) == (@__FILE__) && run_gate(ARGS)
