# One Runtime benchmarks job, for the run page (runtime-run/): its artifacts fetched from
# Buildkite when first asked for, reduced to what the page draws, and kept in memory. A
# finished job's artifacts never change, so an entry is never refreshed, only evicted.
#
# Only jobs named like the Runtime benchmarks job of the three pipelines that run it are
# fetched, and only their runtime-benchmarks/out/ artifacts. Fetches of jobs not yet in
# the cache are capped per time window, so the API cannot be used to spend the token's
# Buildkite budget.
module RuntimeRun

using HTTP, JSON3, CodecZlib
include(joinpath(@__DIR__, "..", "db", "Fetch.jl"))

const PIPELINES = ("julia-pr", "julia-ci", "julia-buildkite-ci")
const JOB_ID = r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
# As fetch_runtime.jl matches the job: ":macos: Runtime benchmarks aarch64-apple-darwin"
const RTB_JOB = r"\bRuntime benchmarks\s+([a-z0-9_]+-[a-z0-9_-]+)$"
const FINISHED_STATES = ("passed", "failed", "timed_out", "canceled")
const ARTIFACT_DIR = "runtime-benchmarks/out/"
# The first comparison, and on a pull request with regressions the confirmation run
# with the control arm
const RUNS = ("" => "main", "confirm/" => "confirm")
const MAX_ARTIFACT_BYTES = 64 * 2^20
const CACHE_ENTRIES = 16
const FETCH_WINDOW_S = 600
const FETCHES_PER_WINDOW = 30

struct BadInput <: Exception
    msg::String
end
struct NotFound <: Exception
    msg::String
end
# The job has not finished: its artifacts may still change, so nothing is cached
struct NotFinished <: Exception
    state::String
end
struct Busy <: Exception end
# The server has no Buildkite token
struct Unavailable <: Exception end

# --runtime-runs DIR: read <DIR>/<pipeline>/<build>/<job>/ (the artifacts under their
# names below runtime-benchmarks/out/, and job.json, the job and build as the Buildkite
# API answers them) instead of Buildkite, for a local preview
const LOCAL_DIR = Ref{Union{Nothing,String}}(nothing)

mutable struct Entry
    summary::Vector{UInt8}                  # gzipped JSON
    samples::Dict{String,Vector{UInt8}}     # "<run>/<benchmark>" => gzipped JSON
    used_at::Float64
end

const LOCK = ReentrantLock()
const CACHE = Dict{String,Entry}()
const INFLIGHT = Dict{String,Task}()
const FETCH_TIMES = Float64[]

function validate(pipeline, build, job)
    pipeline in PIPELINES || throw(BadInput("pipeline must be one of " * join(PIPELINES, ", ")))
    n = tryparse(Int, build)
    (n === nothing || n <= 0 || string(n) != build) && throw(BadInput("build must be a positive build number"))
    occursin(JOB_ID, job) || throw(BadInput("job must be a Buildkite job UUID"))
    return n
end

"""
    summary(pipeline, build, job) -> gzipped JSON
    samples(pipeline, build, job, run, bench) -> gzipped JSON

What the run page draws of one job, fetched on first use. `run` is "main" or "confirm".
Throws `BadInput`, `NotFound`, `NotFinished`, `Busy` or `Unavailable`.
"""
summary(pipeline, build, job) = entry(pipeline, build, job).summary

function samples(pipeline, build, job, run, bench)
    run in last.(RUNS) || throw(BadInput("run must be main or confirm"))
    e = entry(pipeline, build, job)
    body = get(e.samples, "$run/$bench", nothing)
    body === nothing && throw(NotFound("no benchmark $bench in the $run run of this job"))
    return body
end

function entry(pipeline, build, job)
    n = validate(pipeline, build, job)
    key = "$pipeline/$n/$job"
    task = lock(LOCK) do
        e = get(CACHE, key, nothing)
        if e !== nothing
            e.used_at = time()
            return e
        end
        t = get(INFLIGHT, key, nothing)
        t === nothing || return t
        # Only a fetch from Buildkite counts against the budget
        if LOCAL_DIR[] === nothing
            filter!(x -> time() - x < FETCH_WINDOW_S, FETCH_TIMES)
            length(FETCH_TIMES) >= FETCHES_PER_WINDOW && throw(Busy())
            push!(FETCH_TIMES, time())
        end
        t = Threads.@spawn :default load(pipeline, n, job)
        INFLIGHT[key] = t
        return t
    end
    task isa Entry && return task
    e = try
        fetch(task)
    catch err
        err isa TaskFailedException ? throw(err.task.exception) : rethrow()
    finally
        lock(() -> delete!(INFLIGHT, key), LOCK)
    end
    lock(LOCK) do
        CACHE[key] = e
        while length(CACHE) > CACHE_ENTRIES
            delete!(CACHE, argmin(k -> CACHE[k].used_at, keys(CACHE)))
        end
    end
    return e
end

# --- fetching ---------------------------------------------------------------------

function load(pipeline, n, job)
    jobinfo, files = LOCAL_DIR[] === nothing ? fetch_remote(pipeline, n, job) : read_local(pipeline, n, job)
    return build_entry(pipeline, n, job, jobinfo, files)
end

function check_job(j)
    occursin(RTB_JOB, String(something(get(j, :name, nothing), ""))) || throw(NotFound("not a Runtime benchmarks job"))
    state = String(something(get(j, :state, nothing), ""))
    state in FINISHED_STATES || throw(NotFinished(state))
end

function fetch_remote(pipeline, n, job)
    token = try
        buildkite_token()
    catch
        throw(Unavailable())
    end
    b = buildkite_get("organizations/$BUILDKITE_ORG/pipelines/$pipeline/builds/$n"; token)
    b === nothing && throw(NotFound("no build $n in $pipeline"))
    i = findfirst(j -> String(something(get(j, :id, nothing), "")) == job, b.jobs)
    i === nothing && throw(NotFound("no job $job in build $n"))
    check_job(b.jobs[i])
    artifacts = buildkite_get("organizations/$BUILDKITE_ORG/pipelines/$pipeline/builds/$n/jobs/$job/artifacts";
                              token, params=["per_page" => 100])
    artifacts === nothing && throw(NotFound("the job's artifacts could not be listed"))
    files = Dict{String,Any}()
    for (dir, _) in RUNS, name in ("results.json", "results-meta.json", "compare.json")
        path = ARTIFACT_DIR * dir * name
        k = findfirst(a -> String(get(a, :path, "")) == path && String(get(a, :state, "")) == "finished", artifacts)
        k === nothing && continue
        something(get(artifacts[k], :file_size, 0), 0) > MAX_ARTIFACT_BYTES && continue
        body = download_artifact(String(artifacts[k].download_url); token)
        body === nothing || (files[dir * name] = JSON3.read(body))
    end
    return (build=b, job=b.jobs[i]), files
end

function read_local(pipeline, n, job)
    dir = joinpath(LOCAL_DIR[], pipeline, string(n), job)
    isdir(dir) || throw(NotFound("no job $job in build $n"))
    info = JSON3.read(read(joinpath(dir, "job.json")))
    check_job(info.job)
    files = Dict{String,Any}()
    for (sub, _) in RUNS, name in ("results.json", "results-meta.json", "compare.json")
        f = joinpath(dir, sub, name)
        isfile(f) && (files[sub * name] = JSON3.read(read(f)))
    end
    return (build=info.build, job=info.job), files
end

# --- the page's shapes ----------------------------------------------------------------

str(x) = x === nothing ? nothing : String(x)
num(x) = x === nothing ? nothing : Float64(x)
getk(o, k, default=nothing) = o === nothing ? default : something(get(o, k, nothing), Some(default))

# compare.jl's judged metric of a record: cycles when the benchmark asks for them and
# the backend recorded them, else wall time
function record_metric(r)
    c = getk(r, :counters, Dict())
    String(getk(r, :metric, "time")) == "cycles" && !isempty(getk(c, :cycles, [])) ? "cycles" : "time"
end
record_samples(r, metric) = Float64.(metric == "cycles" ? r.counters.cycles : r.times_ns)

function quantile_sorted(v, p)
    isempty(v) && return nothing
    h = (length(v) - 1) * p + 1
    lo = floor(Int, h)
    return lo >= length(v) ? v[end] : v[lo] + (h - lo) * (v[lo+1] - v[lo])
end
# compare.jl's per-block value: the 5th percentile, as an order statistic
low(v) = isempty(v) ? nothing : sort(v)[cld(length(v), 20)]

function cell(r)
    status = String(getk(r, :status, ""))
    status == "ok" || return Dict("block" => getk(r, :block), "status" => status, "error" => str(getk(r, :error)))
    metric = record_metric(r)
    v = sort(record_samples(r, metric))
    ins = getk(getk(r, :counters, nothing), :instructions, [])
    return Dict("block" => getk(r, :block), "status" => "ok", "metric" => metric, "n" => length(v),
                "value" => low(v), "q" => [v[1], quantile_sorted(v, 0.25), quantile_sorted(v, 0.5), quantile_sorted(v, 0.75), v[end]],
                "instructions" => isempty(ins) ? nothing : Float64(minimum(ins)),
                "min_ns" => num(getk(r, :min_ns)), "median_ns" => num(getk(r, :median_ns)),
                "allocs" => getk(r, :allocs), "bytes" => getk(r, :bytes),
                "gc_ns" => (g = getk(r, :gc_ns, []); g isa AbstractVector ? sum(g; init=0) / max(length(g), 1) : g))
end

function arm_info(meta, a)
    i = getk(getk(meta, :arms, nothing), Symbol(a), nothing)
    i === nothing && return Dict("name" => a)
    return Dict("name" => a, "commit" => str(getk(i, :commit)), "version" => str(getk(i, :version)),
                "llvm" => str(getk(i, :llvm)), "date" => str(getk(i, :date)), "cpu_target" => str(getk(i, :cpu_target)))
end

# compare.json's verdicts by benchmark (and category); old jobs' have no control
function verdicts(compare)
    compare === nothing && return Dict{String,Any}(), Any[]
    bench = Dict{String,Any}()
    for b in compare.benchmarks
        c = getk(b, :control)
        bench[String(b.name)] = Dict("verdict" => String(b.verdict), "ratio" => num(getk(b, :ratio)),
                                     "ratios" => [Float64(x) for x in getk(b, :ratios, [])], "tolerance" => num(getk(b, :tolerance)),
                                     "instr_ratio" => num(getk(b, :instr_ratio)), "instr_changed" => getk(b, :instr_changed, false),
                                     "mixed_units" => getk(b, :mixed_units, false), "vetoed" => getk(b, :vetoed, false),
                                     "alloc_change" => getk(b, :alloc_change),
                                     "control_ratio" => c === nothing ? nothing : num(getk(c, :ratio)),
                                     "control_ratios" => c === nothing ? nothing : [Float64(x) for x in getk(c, :ratios, [])])
    end
    cats = Any[]
    for s in getk(compare, :categories, [])
        c = getk(s, :control)
        push!(cats, Dict("category" => String(s.category), "geomean" => num(s.geomean), "verdict" => String(s.verdict),
                         "per_block" => [Float64(x) for x in getk(s, :per_block, [])], "n" => getk(s, :n),
                         "vetoed" => getk(s, :vetoed, false), "control_geomean" => c === nothing ? nothing : num(getk(c, :geomean))))
    end
    return bench, cats
end

# One run (the first comparison or the confirmation): its arms, settings and per
# benchmark the verdict and every arm's blocks; and the samples per benchmark
function run_shape(results, meta, compare)
    arms = String[String(a) for a in getk(meta, :arm_order, [])]
    isempty(arms) && (arms = sort!(unique(String(r.arm) for r in results)))
    vb, cats = verdicts(compare)
    byname = Dict{String,Vector{Any}}()
    order = String[]
    for r in results
        name = String(r.name)
        haskey(byname, name) || (push!(order, name); byname[name] = Any[])
        push!(byname[name], r)
    end
    benchmarks = Any[]
    samples = Dict{String,Any}()
    for name in order
        recs = byname[name]
        r1 = recs[something(findfirst(r -> String(getk(r, :status, "")) == "ok", recs), 1)]
        perarm = Dict{String,Any}()
        sam = Dict{String,Any}()
        for a in arms
            rs = sort!(filter(r -> String(r.arm) == a, recs); by=r -> something(getk(r, :block), 0))
            perarm[a] = [cell(r) for r in rs]
            sam[a] = [begin
                ok = String(getk(r, :status, "")) == "ok"
                m = ok ? record_metric(r) : nothing
                Dict("block" => getk(r, :block), "metric" => m, "values" => ok ? record_samples(r, m) : Float64[],
                     "instructions" => ok ? Float64.(getk(getk(r, :counters, nothing), :instructions, [])) : Float64[])
            end for r in rs]
        end
        push!(benchmarks, Dict("name" => name, "category" => String(getk(r1, :category, first(split(name, '/')))),
                               "metric" => record_metric(r1), "ops" => getk(r1, :ops, 1), "tolerance" => num(getk(r1, :tolerance)),
                               "arms" => perarm, "compare" => get(vb, name, nothing)))
        samples[name] = Dict("name" => name, "arms" => sam)
    end
    shape = Dict("arms" => [arm_info(meta, a) for a in arms], "arm_order" => arms,
                 "base" => compare === nothing ? nothing : str(getk(compare, :base)),
                 "head" => compare === nothing ? (length(arms) == 1 ? arms[1] : nothing) : str(getk(compare, :head)),
                 "control" => compare === nothing ? nothing : str(getk(compare, :control)),
                 "machine" => getk(meta, :machine), "settings" => getk(meta, :settings),
                 "suite_commit" => str(getk(meta, :suite_commit)), "duration_s" => num(getk(meta, :duration_s)),
                 "started" => str(getk(meta, :started)), "failures" => getk(meta, :failures, []),
                 "incomplete" => compare === nothing ? nothing : getk(compare, :incomplete),
                 "compared" => compare !== nothing, "benchmarks" => benchmarks, "categories" => cats)
    return shape, samples
end

function github_repo(url)
    m = url === nothing ? nothing : match(r"github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?$", url)
    return m === nothing ? "JuliaLang/julia" : String(m.captures[1])
end

gz(x) = transcode(GzipCompressor, Vector{UInt8}(JSON3.write(x)))

function build_entry(pipeline, n, job, info, files)
    haskey(files, "results.json") || throw(NotFound("the job uploaded no results"))
    b, j = info.build, info.job
    pr = getk(b, :pull_request)
    out = Dict{String,Any}("pipeline" => pipeline, "build" => n, "job_id" => job,
                           "job_url" => str(getk(j, :web_url)), "job_state" => str(getk(j, :state)),
                           "job_name" => str(getk(j, :name)), "finished_at" => str(getk(j, :finished_at)),
                           "build_url" => str(getk(b, :web_url)), "message" => str(getk(b, :message)),
                           "commit" => str(getk(b, :commit)), "branch" => str(getk(b, :branch)),
                           "pr" => pr === nothing ? nothing : (x = getk(pr, :id); x === nothing ? nothing : tryparse(Int, string(x))),
                           # owner/name on GitHub, for the pull request's link (the self-test's are julia-buildkite's)
                           "pr_repo" => pr === nothing ? nothing : github_repo(str(getk(pr, :repository))))
    samples = Dict{String,Vector{UInt8}}()
    for (dir, run) in RUNS
        haskey(files, dir * "results.json") || continue
        shape, sam = run_shape(files[dir * "results.json"], get(files, dir * "results-meta.json", nothing),
                               get(files, dir * "compare.json", nothing))
        out[run] = shape
        for (name, s) in sam
            samples["$run/$name"] = gz(s)
        end
    end
    return Entry(gz(out), samples, time())
end

end # module
