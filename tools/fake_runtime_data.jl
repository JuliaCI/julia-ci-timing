#!/usr/bin/env julia
# Write a database of synthetic runtime benchmark history, for previewing the Runtime tab
# (?tab=ci-runtime) without the julia-ci jobs that will feed it.
#
# It takes the values of a real run of JuliaCI/julia-ci-benchmarks (a results.json, of
# which the `head` arm is used) as the level of every benchmark, and writes about 150
# julia-ci master builds over 75 days around them through fetch_runtime.jl's own
# `job_row` and `write_rows!`, so the rows are what the fetcher would store. Cycles move
# by about 1% from block to block and build to build, wall time by about 3% with an
# occasional outlier, and instruction counts are exact except where an event changes the
# code. The events:
#
# - an LLVM bump that moves most of `simd` and `scalar` by a few percent, with their
#   instruction counts
# - a regression of `collections/dict_string_count` that a later build fixes
# - a GC improvement across the `gc` category
# - a compiler slowdown across `compiler/*`
# - `io/file_roundtrip` failing for a few builds, one job with no results at all, and
#   `types/show_types` failing in the newest build
# - a step in `parallel` from an agent update, annotated in runtime_annotations.json (one
#   illustrative note, written next to the database; the repository's file stays empty)
#
# It also writes four open pull requests with a compare.json judged as
# julia-ci-benchmarks' compare.jl does: one regressing, one improving, one clean and a
# draft. With --julia-repo, the builds take real master commits (first parent, spread
# over the 75 days) and their subjects from that checkout, so the commit links work;
# otherwise the SHAs are made up and only GitHub's own 404 page is behind them.
#
# Preview:
#
#   julia --project tools/fake_runtime_data.jl --results path/to/results.json \
#       --db /tmp/rtb/fake.sqlite --julia-repo ~/julia
#   julia --project db/serve.jl --db /tmp/rtb/fake.sqlite --site . --notes /tmp/rtb --port 8002
#   open 'http://127.0.0.1:8002/?tab=ci-runtime'
#
# The other tabs have no data in that database; the Overview shows them as missing.

using Pkg
Pkg.activate(dirname(@__DIR__); io=devnull)
using JSON3, Dates, Random, SQLite, DBInterface
using CITiming.Store

# The fetcher defines the row shapes and the writes; its main only runs as a script
module RuntimeFetcher
include(joinpath(dirname(@__DIR__), "fetch_runtime.jl"))
end
using .RuntimeFetcher: job_row, write_rows!, pr_row, write_prs!

function parse_args(args)
    opts = Dict{String,Any}("results" => nothing, "db" => nothing, "notes" => nothing, "julia-repo" => nothing,
                            "builds" => 150, "days" => 75, "seed" => 1)
    i = 1
    while i <= length(args)
        k = args[i]
        startswith(k, "--") && haskey(opts, k[3:end]) || error("unknown argument $k")
        v = args[i+1]
        opts[k[3:end]] = k in ("--builds", "--days", "--seed") ? parse(Int, v) : v
        i += 2
    end
    opts["results"] === nothing && error("pass --results path/to/results.json (or the directory holding it)")
    opts["db"] === nothing && error("pass --db path/to/new.sqlite")
    isdir(opts["results"]) && (opts["results"] = joinpath(opts["results"], "results.json"))
    opts["notes"] === nothing && (opts["notes"] = dirname(abspath(opts["db"])))
    return opts
end

# --- the base level of each benchmark ----------------------------------------------

struct BenchBase
    name::String
    category::String
    metric::String
    ops::Int
    tolerance::Any
    cycles::Union{Nothing,Float64}
    instructions::Union{Nothing,Float64}
    ns::Float64
    median_ratio::Float64
    allocs::Int
    bytes::Int
    backend::String
end

function load_base(path)
    recs = JSON3.read(read(path, String))
    arms = unique(String(r.arm) for r in recs)
    arm = "head" in arms ? "head" : arms[1]
    out = Dict{String,BenchBase}()
    for r in recs
        (String(r.arm) == arm && r.status == "ok") || continue
        c = r.counters
        cyc = haskey(c, :cycles) && !isempty(c.cycles) ? Float64(minimum(c.cycles)) : nothing
        ins = haskey(c, :instructions) && !isempty(c.instructions) ? Float64(minimum(c.instructions)) : nothing
        b = BenchBase(String(r.name), String(r.category), String(r.metric), Int(r.ops), r.tolerance, cyc, ins, Float64(r.min_ns),
                  Float64(r.median_ns) / Float64(r.min_ns), Int(r.allocs), Int(r.bytes), String(r.counters_backend))
        old = get(out, b.name, nothing)
        # The block with the lowest value is the level
        (old === nothing || b.ns < old.ns) && (out[b.name] = b)
    end
    return out
end

# --- the history ---------------------------------------------------------------

# Each event multiplies a benchmark's level (value, and for its instructions `instr`)
# from build `from` on, until `until` when given
struct Event
    from::Int
    until::Int
    effects::Dict{String,Tuple{Float64,Float64}}   # name => (value factor, instruction factor)
end

function events(base, n, rng)
    names = sort!(collect(keys(base)))
    incat(c) = filter(x -> base[x].category == c, names)
    at(f) = round(Int, f * n)
    evs = Event[]
    # The LLVM bump: most of simd and scalar move, mostly faster, and run other code
    llvm = Dict{String,Tuple{Float64,Float64}}()
    for x in [incat("simd"); incat("scalar")]
        rand(rng) < 0.8 || continue
        v = rand(rng) < 0.75 ? 1 - (0.02 + 0.05rand(rng)) : 1 + (0.02 + 0.03rand(rng))
        llvm[x] = (v, 1 + (v - 1) * (0.8 + 0.6rand(rng)))
    end
    push!(evs, Event(at(0.40), n + 1, llvm))
    # One benchmark regresses and is fixed later
    push!(evs, Event(at(0.56), at(0.67), Dict("collections/dict_string_count" => (1.19, 1.13))))
    # The GC gets faster across its category; the calling thread runs a little less code
    push!(evs, Event(at(0.73), n + 1, Dict(x => (1 - (0.08 + 0.07rand(rng)), 0.99) for x in incat("gc"))))
    # The compiler gets slower
    push!(evs, Event(at(0.83), n + 1, Dict(x => (1 + (0.04 + 0.03rand(rng)), 1.05 + 0.01rand(rng)) for x in incat("compiler"))))
    # The agent update behind the annotation: the threads land differently, and only wall time sees it
    push!(evs, Event(at(0.62), n + 1, Dict(x => (1.05, 1.0) for x in incat("parallel"))))
    return evs
end

level(evs, name, k) = foldl(((v, i), e) -> e.from <= k < e.until && haskey(e.effects, name) ? (v * e.effects[name][1], i * e.effects[name][2]) : (v, i),
                            evs; init=(1.0, 1.0))

# The builds' commits: real ones from a checkout's first-parent master history, spread
# evenly over the window, or made up
function commits(opts, n, t0, t1, rng)
    repo = opts["julia-repo"]
    if repo !== nothing
        since = Dates.format(t0, dateformat"yyyy-mm-dd")
        lines = readlines(`git -C $repo log --first-parent --format=%H%x09%ct%x09%s origin/master --since=$since`)
        if length(lines) >= n
            picked = reverse(lines)[round.(Int, range(1, length(lines); length=n))]
            return map(picked) do l
                sha, t, subject = split(l, '\t'; limit=3)
                (sha=String(sha), time=unix2datetime(parse(Int, t)), message=String(subject))
            end
        end
        @warn "The checkout has too few master commits in the window; making them up" repo found=length(lines)
    end
    return [(sha=bytes2hex(rand(rng, UInt8, 20)), time=t0 + Millisecond(round(Int, (k - 1) / (n - 1) * Dates.value(t1 - t0))),
             message="Synthetic master commit $k for the runtime benchmark preview") for k in 1:n]
end

const SAMPLES = 5

# One block's record, shaped as julia-ci-benchmarks' results.json has it, with a few samples
function record(b::BenchBase, arm, block, order, cycles, instructions, ns, version; status="ok", error=nothing)
    jitter(x, s) = [x * (1 + s * abs(randn())) for _ in 1:SAMPLES]
    counters = Dict{String,Any}()
    if status == "ok"
        b.cycles === nothing || (counters["cycles"] = round.(Int, sort!(jitter(cycles, 0.01))))
        b.instructions === nothing || (counters["instructions"] = round.(Int, [instructions; fill(instructions, SAMPLES - 1) .* (1 .+ 1e-6 .* rand(SAMPLES - 1))]))
    end
    times = status == "ok" ? round.(Int, sort!(jitter(ns, 0.02))) : Int[]
    return Dict{String,Any}(
        "name" => b.name, "category" => b.category, "arm" => arm, "block" => block, "order" => order, "status" => status,
        "error" => error, "metric" => b.metric, "tolerance" => b.tolerance, "times_ns" => times,
        "min_ns" => isempty(times) ? nothing : minimum(times), "median_ns" => isempty(times) ? nothing : round(Int, times[1] * b.median_ratio),
        "counters" => counters, "counters_backend" => b.backend, "allocs" => b.allocs, "bytes" => b.bytes,
        "gc_ns" => zeros(Int, length(times)), "ops" => b.ops, "julia_version" => version,
        "threads" => b.category == "parallel" ? 4 : 1)
end

# A benchmark's value (cycles or ns) and instructions in one block of build `k`:
# `build_noise` is shared by the build's blocks, the process adds its own
function block_values(b::BenchBase, lv, li, build_noise, rng)
    time = b.metric == "time" || b.cycles === nothing
    sd = time ? 0.012 : 0.003
    noise = exp(build_noise + sd * randn(rng))
    # Wall time has the occasional slow process: frequency scaling, an efficiency core
    time && rand(rng) < 0.04 && (noise *= 1.08 + 0.15rand(rng))
    ns = b.ns * lv * (time ? noise : exp(build_noise + 0.02 * randn(rng)))
    cycles = b.cycles === nothing ? nothing : b.cycles * lv * noise
    # Exact, except for a time benchmark, whose calling thread does a varying share of the work
    instr = b.instructions === nothing ? nothing : round(b.instructions * li * (time ? 1 + 0.002randn(rng) : 1.0))
    return cycles, instr, ns
end

function version_of(k)
    return "1.14.0-DEV.$(1450 + 3k)"
end

function main(args)
    opts = parse_args(args)
    rng = MersenneTwister(opts["seed"])
    Random.seed!(opts["seed"])
    base = load_base(opts["results"])
    names = sort!(collect(keys(base)))
    n = opts["builds"]
    t1 = floor(now(UTC), Hour) - Hour(2)
    t0 = t1 - Day(opts["days"])
    evs = events(base, n, rng)
    cs = commits(opts, n, t0, t1, rng)
    llvm_bump = evs[1].from
    nobuild = round(Int, 0.5n)                     # the job uploaded nothing
    io_fail = round(Int, 0.25n):round(Int, 0.25n) + 3
    isfile(opts["db"]) && rm(opts["db"])
    mkpath(dirname(abspath(opts["db"])))
    db = Store.open_db(opts["db"])
    number = 1480
    builds = Any[]
    source_run(db, "runtime") do
        rows = Any[]
        for k in 1:n
            c = cs[k]
            number += rand(rng, 1:4)
            created = c.time + Minute(rand(rng, 1:20))
            started = created + Minute(40 + rand(rng, 0:30))
            finished = started + Minute(22 + rand(rng, 0:4))
            version = version_of(k)
            llvm = k >= llvm_bump ? "21.1.2" : "20.1.8"
            uuid = string(Base.UUID(rand(rng, UInt128)))
            build = JSON3.read(JSON3.write(Dict("number" => number, "created_at" => Store.iso(created), "commit" => c.sha,
                                                "message" => c.message, "branch" => "master")))
            job = JSON3.read(JSON3.write(Dict("id" => uuid, "state" => k == nobuild ? "failed" : "passed",
                                              "started_at" => Store.iso(started), "finished_at" => Store.iso(finished),
                                              "web_url" => "https://buildkite.com/julialang/julia-ci/builds/$number#$uuid",
                                              "agent" => Dict("hostname" => "macmini-arm64-$(rand(rng, 1:2)).julia.csail.mit.edu"))))
            meta = Dict{String,Any}(
                "arm_order" => ["head"],
                "arms" => Dict("head" => Dict("commit" => c.sha, "version" => version, "llvm" => llvm, "cpu_target" => "apple-m4",
                                              "date" => Dates.format(created, "yyyy-mm-dd HH:MM") * " UTC")),
                "machine" => Dict("arch" => "aarch64", "cpu" => "Apple M4 Pro", "os" => "Darwin", "ncpu" => 14, "perf_cores" => 10,
                                  "efficiency_cores" => 4, "memory_gib" => 24.0, "model" => "Mac16,7"),
                "settings" => Dict("blocks" => 3, "threads" => 4, "categories" => unique(base[x].category for x in names), "filter" => "",
                                   "seconds_scale" => 1.0),
                "suite_commit" => "9f3c2e1a7b5d4c8e6f0a1b2c3d4e5f6a7b8c9d0e", "duration_s" => 1300 + 60rand(rng),
                "failures" => Any[], "started" => Store.iso(started))
            records = Any[]
            if k != nobuild
                order = 0
                build_noise = Dict(x => 0.003 * randn(rng) for x in names)
                for block in 1:3, x in names
                    b = base[x]
                    order += 1
                    if x == "io/file_roundtrip" && k in io_fail
                        push!(records, record(b, "head", block, order, 0, 0, 0, version; status="error",
                                              error="SystemError: opening file \"/private/var/folders/rtb/roundtrip.bin\": Too many open files"))
                        continue
                    end
                    if x == "types/show_types" && k == n
                        push!(records, record(b, "head", block, order, 0, 0, 0, version; status="error",
                                              error="MethodError: no method matching show(::IOContext{IOBuffer}, ::Type{Vararg})"))
                        continue
                    end
                    lv, li = level(evs, x, k)
                    cyc, ins, ns = block_values(b, lv, li, build_noise[x], rng)
                    push!(records, record(b, "head", block, order, cyc, ins, ns, version))
                end
            end
            results = k == nobuild ? nothing : JSON3.read(JSON3.write(records))
            push!(rows, job_row(build, job, results, JSON3.read(JSON3.write(meta))))
            push!(builds, (; k, number, uuid, created, sha=c.sha, version, llvm))
        end
        transaction(db) do
            write_rows!(db, rows)
        end
        write_fake_prs!(db, base, names, evs, builds[end], rng)
        return length(rows)
    end
    # The illustrative note, at the agent update
    k = evs[5].from
    note = Dict("schema_version" => 1, "annotations" => [Dict(
        "build" => builds[k].number, "kind" => "runner",
        "label" => "macOS 26.6 → 27 (example)",
        "description" => "An illustrative note from tools/fake_runtime_data.jl: the agent's macOS was updated, which moved the parallel " *
                         "benchmarks' wall time by about 5% without any Julia commit being responsible.",
        "categories" => ["parallel"])])
    mkpath(opts["notes"])
    write(joinpath(opts["notes"], "runtime_annotations.json"), JSON3.write(note))
    close(db)
    println("wrote $(opts["db"]): $n builds from $(Date(t0)) to $(Date(t1)), $(length(names)) benchmarks; notes in $(opts["notes"])")
end

# --- pull requests -------------------------------------------------------------

const DEFAULT_TOL = Dict("cycles" => 0.03, "time" => 0.06)
const FLOOR = Dict("cycles" => 5_000, "time" => 2_000)
const INSTR_TOL = 0.005
const SUITE_TOL = 0.015

# What julia-ci-benchmarks' compare.jl writes to compare.json for these per-block values
function judge(base, names, blocks; errors=Dict{String,Any}())
    rows = Any[]
    for x in names
        haskey(blocks, x) || continue
        bv = base[x]
        metric = bv.cycles === nothing ? "time" : bv.metric
        b, h = blocks[x].base, blocks[x].head
        tol = something(bv.tolerance, DEFAULT_TOL[metric])
        ratios = [h[i].value / b[i].value for i in 1:3]
        floor_ok = abs(minimum(v.value for v in h) - minimum(v.value for v in b)) >= FLOOR[metric]
        hv, bvv = [v.value for v in h], [v.value for v in b]
        verdict = all(>(1 + tol), ratios) && minimum(hv) > maximum(bvv) && floor_ok ? "regression" :
                  all(<(1 / (1 + tol)), ratios) && maximum(hv) < minimum(bvv) && floor_ok ? "improvement" : "same"
        instr_ratio = metric != "cycles" || bv.instructions === nothing ? nothing : minimum(v.instr for v in h) / minimum(v.instr for v in b)
        instr_changed = instr_ratio !== nothing && abs(instr_ratio - 1) > INSTR_TOL
        push!(rows, Dict{String,Any}(
            "name" => x, "category" => bv.category, "metric" => metric, "tolerance" => tol, "verdict" => verdict,
            "base" => minimum(bvv), "head" => minimum(hv), "ratio" => minimum(hv) / minimum(bvv), "ratios" => ratios,
            "base_time" => minimum(v.ns for v in b), "head_time" => minimum(v.ns for v in h), "instr_ratio" => instr_ratio,
            "instr_changed" => instr_changed, "allocs_base" => bv.allocs, "allocs_head" => bv.allocs, "blocks" => 3))
    end
    cats = Any[]
    for c in sort!(unique(r["category"] for r in rows))
        rs = filter(r -> r["category"] == c, rows)
        g(xs) = exp(sum(log, xs) / length(xs))
        per_block = [g([r["ratios"][i] for r in rs]) for i in 1:3]
        verdict = all(>(1 + SUITE_TOL), per_block) ? "regression" : all(<(1 / (1 + SUITE_TOL)), per_block) ? "improvement" : "same"
        push!(cats, Dict("category" => c, "geomean" => g([r["ratio"] for r in rs]), "per_block" => per_block, "verdict" => verdict, "n" => length(rs)))
    end
    return Dict("base" => "base", "head" => "head", "benchmarks" => rows, "categories" => cats, "errors" => errors, "failures" => Any[])
end

function write_fake_prs!(db, base, names, evs, master, rng)
    incat(c) = filter(x -> base[x].category == c, names)
    specs = [
        (60101, "codegen: Emit `llvm.assume` for array lengths after bounds checks", "vchuravy", false,
         Dict(x => (0.88 + 0.06rand(rng), 0.9) for x in [incat("simd")[1:5]; "array/stencil_3d_cartesian"; "array/view_strided_sum"]), Dict()),
        (60102, "inference: Split unions of up to eight members", "aviatesk", false,
         merge(Dict(x => (1.07 + 0.05rand(rng), 1.06) for x in incat("dispatch")), Dict(x => (1.03, 1.02) for x in incat("compiler"))), Dict()),
        (60103, "docs: Fix typos in the performance tips", "KristofferC", false, Dict(), Dict()),
        (60104, "gc: Allocate small objects from a bump region", "d-netto", true,
         Dict(x => (0.86 + 0.06rand(rng), 0.97) for x in incat("gc") if x != "gc/finalizers"),
         Dict("gc/finalizers" => Dict("head" => "AssertionError: finalizer ran twice"))),
    ]
    rows = Any[]
    for (k, (number, title, author, draft, effects, errors)) in enumerate(specs)
        blocks = Dict{String,Any}()
        for x in names
            haskey(errors, x) && continue
            lb, ib = level(evs, x, master.k)
            f, fi = get(effects, x, (1.0, 1.0))
            b, h = Any[], Any[]
            for _ in 1:3
                noise = 0.003 * randn(rng)
                c1, i1, n1 = block_values(base[x], lb, ib, noise, rng)
                c2, i2, n2 = block_values(base[x], lb * f, ib * fi, noise, rng)
                push!(b, (value=something(c1, n1), instr=something(i1, 0.0), ns=n1))
                push!(h, (value=something(c2, n2), instr=something(i2, 0.0), ns=n2))
            end
            blocks[x] = (base=b, head=h)
        end
        compare = JSON3.read(JSON3.write(judge(base, names, blocks; errors)))
        head_sha = bytes2hex(rand(rng, UInt8, 20))
        version = "1.14.0-DEV.$(1450 + 3 * master.k + k)"
        meta = JSON3.read(JSON3.write(Dict("arm_order" => ["base", "head"], "arms" => Dict(
            "base" => Dict("commit" => master.sha, "version" => master.version, "llvm" => master.llvm),
            "head" => Dict("commit" => head_sha, "version" => version, "llvm" => master.llvm)))))
        # Measured against the newest master build, some hours ago
        created = floor(now(UTC), Minute) - Hour(6 - k)
        uuid = string(Base.UUID(rand(rng, UInt128)))
        bnum = 98000 + 7k
        build = JSON3.read(JSON3.write(Dict("number" => bnum, "created_at" => Store.iso(created), "commit" => head_sha)))
        job = JSON3.read(JSON3.write(Dict("id" => uuid, "state" => "passed", "finished_at" => Store.iso(created + Hour(1)),
                                          "web_url" => "https://buildkite.com/julialang/julia-pr/builds/$bnum#$uuid")))
        # The second has moved on since its job
        pull = JSON3.read(JSON3.write(Dict("number" => number, "title" => title, "user" => Dict("login" => author), "draft" => draft,
                                           "head" => Dict("sha" => k == 2 ? bytes2hex(rand(rng, UInt8, 20)) : head_sha),
                                           "base" => Dict("ref" => "master"))))
        push!(rows, pr_row(pull, build, job, compare, meta))
    end
    transaction(db) do
        write_prs!(db, rows)
    end
end

main(ARGS)
