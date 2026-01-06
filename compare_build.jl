#!/usr/bin/env julia
#
# Compare a Buildkite build's timing against recent master commits
#
# Usage:
#   julia compare_build.jl <build_number> [--baseline-commits N] [--threshold PERCENT] [--json]
#
# Environment variables:
#   BUILDKITE_API_TOKEN - Required for API access
#
# Exit codes:
#   0 - No significant regressions
#   1 - Significant regressions detected
#   2 - Error (missing data, API failure, etc.)

using HTTP
using JSON3
using Statistics
using Printf
using Dates

const BUILDKITE_ORG = "julialang"
const BUILDKITE_PIPELINE = "julia-master"
const API_BASE = "https://api.buildkite.com/v2"
const DATABASE_PATH = joinpath(@__DIR__, "data", "timing_summary.json")
const JULIA_REPO_URL = "https://github.com/JuliaLang/julia.git"
const JULIA_REPO_CACHE = joinpath(@__DIR__, ".julia-repo-cache")

# Statistical significance threshold (p-value)
const P_VALUE_THRESHOLD = 0.05

# Default number of baseline builds
const DEFAULT_BASELINE_COMMITS = 20

# Job name patterns to skip by default (mechanical/infrastructure jobs)
const MECHANICAL_JOB_PATTERNS = [
    r"\bupload\b"i,        # Any job with "upload" as a word
    r"^Launch"i,           # "Launch test jobs" etc.
    r"^Unlock"i,           # "Unlock secrets, launch pipelines"
    r"^:pipeline:"i,       # Pipeline trigger jobs
    r"trigger"i,           # Trigger jobs
    r"^Block"i,            # Block steps
    r"^Wait"i,             # Wait steps
]

struct JobTiming
    name::String
    duration::Float64
    state::String
    agent::String
end

struct ComparisonResult
    job::String
    current_duration::Float64
    baseline_mean::Float64
    baseline_std::Float64
    baseline_n::Int
    percent_change::Float64
    z_score::Float64
    p_value::Float64
    significant::Bool
    regression::Bool  # true = slower, false = faster
end

function get_api_token()
    token = get(ENV, "BUILDKITE_API_TOKEN", "")
    if isempty(token)
        error("BUILDKITE_API_TOKEN environment variable is required")
    end
    return token
end

function api_request(endpoint::String, token::String)
    headers = [
        "Authorization" => "Bearer $token",
        "Content-Type" => "application/json"
    ]

    url = startswith(endpoint, "http") ? endpoint : "$API_BASE$endpoint"

    try
        response = HTTP.get(url, headers; status_exception=false)
        if response.status == 200
            return JSON3.read(String(response.body))
        elseif response.status == 429
            # Rate limited - wait and retry
            sleep(2)
            return api_request(endpoint, token)
        else
            @warn "API request failed" url status=response.status
            return nothing
        end
    catch e
        @warn "API request error" url exception=e
        return nothing
    end
end

function fetch_build_jobs(build_number::Int, token::String; pipeline::String=BUILDKITE_PIPELINE)
    endpoint = "/organizations/$BUILDKITE_ORG/pipelines/$pipeline/builds/$build_number"
    build = api_request(endpoint, token)

    if build === nothing
        return nothing
    end

    jobs = JobTiming[]
    for job in get(build, :jobs, [])
        # Skip non-command jobs (wait steps, etc.)
        if get(job, :type, "") != "script"
            continue
        end

        name = get(job, :name, "")
        state = get(job, :state, "")

        # Only include finished jobs
        if state ∉ ["passed", "failed", "timed_out"]
            continue
        end

        # Calculate duration
        started = get(job, :started_at, nothing)
        finished = get(job, :finished_at, nothing)

        if started === nothing || finished === nothing
            continue
        end

        start_time = DateTime(started[1:19], dateformat"yyyy-mm-ddTHH:MM:SS")
        end_time = DateTime(finished[1:19], dateformat"yyyy-mm-ddTHH:MM:SS")
        duration = Dates.value(end_time - start_time) / 1000.0  # seconds

        agent_name = ""
        agent = get(job, :agent, nothing)
        if agent !== nothing
            agent_name = get(agent, :name, "")
        end

        push!(jobs, JobTiming(name, duration, state, agent_name))
    end

    return jobs
end

function fetch_recent_master_builds(n::Int, token::String; pipeline::String=BUILDKITE_PIPELINE)
    endpoint = "/organizations/$BUILDKITE_ORG/pipelines/$pipeline/builds?branch=master&state=passed&per_page=$n"
    builds = api_request(endpoint, token)

    if builds === nothing
        return Int[]
    end

    return [b.number for b in builds]
end

"""
Fetch build metadata (branch, commit) from Buildkite API.
"""
function fetch_build_info(build_number::Int, token::String; pipeline::String=BUILDKITE_PIPELINE)
    endpoint = "/organizations/$BUILDKITE_ORG/pipelines/$pipeline/builds/$build_number"
    build = api_request(endpoint, token)
    if build === nothing
        return nothing
    end

    # Extract PR number from pull_request field if present
    pr_number = nothing
    pr_data = get(build, :pull_request, nothing)
    if pr_data !== nothing
        pr_id = get(pr_data, :id, nothing)
        if pr_id !== nothing
            pr_number = tryparse(Int, string(pr_id))
        end
    end

    return (
        branch = String(get(build, :branch, "")),
        commit = String(get(build, :commit, "")),
        pr_number = pr_number,
    )
end

"""
Ensure the Julia repo cache exists and is up to date.
Returns the path to the cached repo.
"""
function ensure_julia_repo_cache(; quiet::Bool=false)
    if isdir(JULIA_REPO_CACHE)
        # Update the cache
        if !quiet
            println("Updating Julia repo cache...")
        end
        run(pipeline(`git -C $JULIA_REPO_CACHE fetch --quiet origin master:refs/heads/master`, devnull))
    else
        # Clone fresh (bare repo with master branch)
        if !quiet
            println("Cloning Julia repo (this may take a moment)...")
        end
        run(pipeline(`git clone --bare --filter=blob:none $JULIA_REPO_URL $JULIA_REPO_CACHE`, devnull))
        # Fetch master branch explicitly
        run(pipeline(`git -C $JULIA_REPO_CACHE fetch origin master:refs/heads/master`, devnull))
    end
    return JULIA_REPO_CACHE
end

"""
Find the merge base between a PR branch commit and master.
Returns the merge base commit SHA (short form).
"""
function find_merge_base(pr_commit::String, repo_path::String)
    # Fetch the PR commit if we don't have it
    try
        run(pipeline(`git -C $repo_path cat-file -e $pr_commit`, devnull, stderr=devnull))
    catch
        # Need to fetch the commit - try fetching all heads
        run(pipeline(`git -C $repo_path fetch --quiet origin`, devnull))
    end

    # Find the merge base (use master branch, not origin/master for bare repo)
    result = readchomp(`git -C $repo_path merge-base $pr_commit master`)
    # Return short SHA (8 chars to match database)
    return String(result[1:min(8, length(result))])
end

"""
Look up the build number for a given commit SHA in the database.
Returns the build number or nothing if not found.
"""
function find_build_for_commit(commit_sha::String; pipeline::String=BUILDKITE_PIPELINE)
    if !isfile(DATABASE_PATH)
        return nothing
    end

    data = JSON3.read(read(DATABASE_PATH, String))
    jobs_data = get(data, :jobs, nothing)
    if jobs_data === nothing
        return nothing
    end

    # Check the first job's records to find the commit
    # (all jobs should have the same builds)
    for job_name in keys(jobs_data)
        job_entry = jobs_data[job_name]
        records = job_entry.recent

        for r in records
            if r.pipeline == pipeline
                record_commit = String(r.commit)
                # Match by prefix (database has 8-char short SHAs)
                if startswith(commit_sha, record_commit) || startswith(record_commit, commit_sha)
                    return Int(r.build)
                end
            end
        end
        # Only need to check one job
        break
    end

    return nothing
end

"""
Determine the appropriate base build for comparison.
For master branch builds, returns nothing (use latest).
For PR builds, finds the merge base and returns the corresponding build number and branch name.
Returns (base_build, branch) tuple, or (nothing, nothing) if master branch or error.
"""
function determine_base_build(build_number::Int, token::String; pipeline::String=BUILDKITE_PIPELINE, quiet::Bool=false)
    # Get build info
    info = fetch_build_info(build_number, token; pipeline=pipeline)
    if info === nothing
        return (nothing, nothing)
    end

    # If it's a master branch build, no special base needed
    if info.branch == "master"
        return (nothing, info.branch)
    end

    if !quiet
        println("PR branch detected: $(info.branch)")
        println("Finding merge base...")
    end

    # Clone/update repo and find merge base
    repo_path = ensure_julia_repo_cache(; quiet=quiet)
    merge_base = find_merge_base(info.commit, repo_path)

    if !quiet
        println("Merge base commit: $merge_base")
    end

    # Find the build number for this commit
    base_build = find_build_for_commit(merge_base; pipeline=pipeline)

    if base_build === nothing && !quiet
        @warn "Could not find build for merge base commit" commit=merge_base
    elseif !quiet
        println("Base build: #$base_build")
    end

    return (base_build, info.branch)
end

"""
Load baseline statistics from the local database (timing_summary.json).
Returns a Dict mapping job names to vectors of durations from the most recent n builds.
If max_build is provided, only considers builds with number <= max_build.
"""
function load_baseline_from_database(n::Int; pipeline::String=BUILDKITE_PIPELINE, max_build::Union{Int,Nothing}=nothing)
    if !isfile(DATABASE_PATH)
        @warn "Database not found" path=DATABASE_PATH
        return nothing
    end

    data = JSON3.read(read(DATABASE_PATH, String))
    jobs_data = get(data, :jobs, nothing)

    if jobs_data === nothing
        @warn "No jobs data in database"
        return nothing
    end

    # Build a mapping of job name -> vector of durations for recent builds
    job_timings = Dict{String, Vector{Float64}}()

    for job_name in keys(jobs_data)
        job_entry = jobs_data[job_name]
        job_name_str = String(job_name)

        # The records are in .recent
        records = job_entry.recent

        # Filter to only this pipeline and passed state, and optionally by max build
        relevant = Tuple{Int, Float64}[]
        for r in records
            if r.pipeline == pipeline && r.state == "passed"
                build_num = Int(r.build)
                if max_build === nothing || build_num <= max_build
                    push!(relevant, (build_num, Float64(r.duration)))
                end
            end
        end

        if isempty(relevant)
            continue
        end

        # Sort by build number descending, take most recent n
        sort!(relevant, by=first, rev=true)
        durations = [d for (_, d) in relevant[1:min(n, length(relevant))]]

        if !isempty(durations)
            job_timings[job_name_str] = durations
        end
    end

    return job_timings
end

function compute_baseline_stats(job_timings::Vector{Vector{JobTiming}})
    # Aggregate timings by job name
    job_data = Dict{String, Vector{Float64}}()

    for build_jobs in job_timings
        for job in build_jobs
            if job.state == "passed"  # Only use passed jobs for baseline
                if !haskey(job_data, job.name)
                    job_data[job.name] = Float64[]
                end
                push!(job_data[job.name], job.duration)
            end
        end
    end

    return job_data
end

# Two-tailed z-test for comparing single value against sample
function z_test(value::Float64, sample_mean::Float64, sample_std::Float64, sample_n::Int)
    if sample_std == 0 || sample_n < 2
        return 0.0, 1.0  # No variance, can't compute
    end

    # Standard error of the mean
    se = sample_std / sqrt(sample_n)

    # Z-score
    z = (value - sample_mean) / se

    # Two-tailed p-value using normal approximation
    # Using the error function approximation
    p = 2 * (1 - normal_cdf(abs(z)))

    return z, p
end

# Normal CDF approximation
function normal_cdf(x::Float64)
    # Abramowitz and Stegun approximation
    a1 =  0.254829592
    a2 = -0.284496736
    a3 =  1.421413741
    a4 = -1.453152027
    a5 =  1.061405429
    p  =  0.3275911

    sign = x < 0 ? -1 : 1
    x = abs(x) / sqrt(2)

    t = 1.0 / (1.0 + p * x)
    y = 1.0 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * exp(-x * x)

    return 0.5 * (1.0 + sign * y)
end

function is_mechanical_job(name::String)
    return any(p -> occursin(p, name), MECHANICAL_JOB_PATTERNS)
end

function compare_build(current_jobs::Vector{JobTiming}, baseline_data::Dict{String, Vector{Float64}};
                       threshold_percent::Float64=10.0, include_mechanical::Bool=false)
    results = ComparisonResult[]

    for job in current_jobs
        if !haskey(baseline_data, job.name)
            continue  # New job, no baseline
        end

        # Skip mechanical jobs unless explicitly included
        if !include_mechanical && is_mechanical_job(job.name)
            continue
        end

        baseline = baseline_data[job.name]
        if length(baseline) < 3
            continue  # Not enough baseline data
        end

        baseline_mean = mean(baseline)
        baseline_std = std(baseline)
        baseline_n = length(baseline)

        percent_change = ((job.duration - baseline_mean) / baseline_mean) * 100
        z_score, p_value = z_test(job.duration, baseline_mean, baseline_std, baseline_n)

        significant = p_value < P_VALUE_THRESHOLD && abs(percent_change) > threshold_percent
        regression = percent_change > 0

        push!(results, ComparisonResult(
            job.name,
            job.duration,
            baseline_mean,
            baseline_std,
            baseline_n,
            percent_change,
            z_score,
            p_value,
            significant,
            regression
        ))
    end

    return results
end

function format_duration(seconds::Float64)
    if seconds < 60
        return @sprintf("%.1fs", seconds)
    elseif seconds < 3600
        mins = floor(Int, seconds / 60)
        secs = round(Int, seconds % 60)
        return secs > 0 ? "$(mins)m $(secs)s" : "$(mins)m"
    else
        hours = floor(Int, seconds / 3600)
        mins = round(Int, (seconds % 3600) / 60)
        return mins > 0 ? "$(hours)h $(mins)m" : "$(hours)h"
    end
end

function print_results(results::Vector{ComparisonResult}; verbose::Bool=false)
    # Sort by percent change (largest regression first)
    sorted = sort(results, by=r -> -r.percent_change)

    regressions = filter(r -> r.significant && r.regression, sorted)
    improvements = filter(r -> r.significant && !r.regression, sorted)

    if !isempty(regressions)
        println("\n🔴 SIGNIFICANT REGRESSIONS:")
        println("=" ^ 80)
        for r in regressions
            println(@sprintf("  %-50s %+.1f%% (%s → %s, p=%.4f)",
                r.job[1:min(50, length(r.job))],
                r.percent_change,
                format_duration(r.baseline_mean),
                format_duration(r.current_duration),
                r.p_value
            ))
        end
    end

    if !isempty(improvements)
        println("\n🟢 SIGNIFICANT IMPROVEMENTS:")
        println("=" ^ 80)
        for r in improvements
            println(@sprintf("  %-50s %.1f%% (%s → %s, p=%.4f)",
                r.job[1:min(50, length(r.job))],
                r.percent_change,
                format_duration(r.baseline_mean),
                format_duration(r.current_duration),
                r.p_value
            ))
        end
    end

    if verbose && isempty(regressions) && isempty(improvements)
        println("\n✅ No significant timing changes detected")
    end

    return regressions, improvements
end

function generate_json_output(results::Vector{ComparisonResult}, build_number::Int)
    regressions = filter(r -> r.significant && r.regression, results)
    improvements = filter(r -> r.significant && !r.regression, results)

    output = Dict(
        "build_number" => build_number,
        "timestamp" => Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SSZ"),
        "summary" => Dict(
            "total_jobs" => length(results),
            "regressions" => length(regressions),
            "improvements" => length(improvements)
        ),
        "regressions" => [Dict(
            "job" => r.job,
            "current_duration" => r.current_duration,
            "baseline_mean" => r.baseline_mean,
            "baseline_std" => r.baseline_std,
            "baseline_n" => r.baseline_n,
            "percent_change" => r.percent_change,
            "p_value" => r.p_value
        ) for r in regressions],
        "improvements" => [Dict(
            "job" => r.job,
            "current_duration" => r.current_duration,
            "baseline_mean" => r.baseline_mean,
            "baseline_std" => r.baseline_std,
            "baseline_n" => r.baseline_n,
            "percent_change" => r.percent_change,
            "p_value" => r.p_value
        ) for r in improvements]
    )

    return JSON3.write(output)
end

function generate_markdown_comment(results::Vector{ComparisonResult}, build_number::Int)
    regressions = filter(r -> r.significant && r.regression, results)
    improvements = filter(r -> r.significant && !r.regression, results)

    lines = String[]

    if !isempty(regressions)
        push!(lines, "## ⚠️ CI Timing Regressions Detected")
        push!(lines, "")
        push!(lines, "The following jobs showed statistically significant slowdowns compared to recent master builds:")
        push!(lines, "")
        push!(lines, "| Job | Change | Baseline | Current | p-value |")
        push!(lines, "|-----|--------|----------|---------|---------|")

        for r in sort(regressions, by=x -> -x.percent_change)
            job_name = length(r.job) > 45 ? r.job[1:42] * "..." : r.job
            push!(lines, @sprintf("| %s | **+%.1f%%** | %s | %s | %.4f |",
                job_name,
                r.percent_change,
                format_duration(r.baseline_mean),
                format_duration(r.current_duration),
                r.p_value
            ))
        end
        push!(lines, "")
    end

    if !isempty(improvements)
        push!(lines, "## ✅ CI Timing Improvements")
        push!(lines, "")
        push!(lines, "| Job | Change | Baseline | Current | p-value |")
        push!(lines, "|-----|--------|----------|---------|---------|")

        for r in sort(improvements, by=x -> x.percent_change)
            job_name = length(r.job) > 45 ? r.job[1:42] * "..." : r.job
            push!(lines, @sprintf("| %s | **%.1f%%** | %s | %s | %.4f |",
                job_name,
                r.percent_change,
                format_duration(r.baseline_mean),
                format_duration(r.current_duration),
                r.p_value
            ))
        end
        push!(lines, "")
    end

    if isempty(regressions) && isempty(improvements)
        push!(lines, "## ✅ No Significant CI Timing Changes")
        push!(lines, "")
        push!(lines, "All job timings are within expected ranges compared to recent master builds.")
    end

    push!(lines, "")
    push!(lines, "<details>")
    push!(lines, "<summary>Analysis details</summary>")
    push!(lines, "")
    push!(lines, "- Build: [#$build_number](https://buildkite.com/julialang/julia-master/builds/$build_number)")
    push!(lines, "- Compared against: last $DEFAULT_BASELINE_COMMITS passed master builds")
    push!(lines, "- Significance threshold: p < 0.05 and >10% change")
    push!(lines, "- Total jobs analyzed: $(length(results))")
    push!(lines, "")
    push!(lines, "</details>")

    return join(lines, "\n")
end

"""
Extract PR number from a Buildkite branch name.
Branch names for PRs are typically like "pull/60497/head".
Returns nothing if not a PR branch.
"""
function extract_pr_number(branch::String)
    m = match(r"^pull/(\d+)/", branch)
    return m === nothing ? nothing : parse(Int, m.captures[1])
end

function generate_comparison_url(jobs::Vector{JobTiming}, build_number::Int, base_build::Int; pr_number::Union{Int,Nothing}=nothing)
    # Format: c=PR:BUILD:BASE:JOB1=DUR1,JOB2=DUR2,...
    # PR is 0 if not a PR build
    # URL encode job names, durations as integers (seconds)
    job_parts = String[]
    for job in jobs
        if is_mechanical_job(job.name)
            continue
        end
        # Encode job name for URL (handles spaces, colons, etc.)
        encoded_name = HTTP.URIs.escapeuri(job.name)
        push!(job_parts, "$(encoded_name)=$(round(Int, job.duration))")
    end

    # Don't double-encode - job names are already encoded, just join with safe delimiters
    pr = pr_number === nothing ? 0 : pr_number
    param = "$(pr):$(build_number):$(base_build):$(join(job_parts, ","))"
    return "https://juliaCI.github.io/julia-ci-timing/?c=$param"
end

function main()
    # Parse arguments
    args = ARGS

    if isempty(args) || args[1] in ["-h", "--help"]
        println("""
        Usage: julia compare_build.jl <build_number> [options]

        Compare a Buildkite build's timing against recent master commits.
        For PR builds, automatically detects the merge base and compares against
        commits from that point in history.

        Options:
          --baseline-commits N   Number of baseline commits to compare against (default: $DEFAULT_BASELINE_COMMITS)
          --base-build N         Override automatic base detection with specific build number
          --threshold PERCENT    Minimum percent change for significance (default: 10)
          --json                 Output results as JSON
          --markdown             Output results as Markdown (for GitHub comments)
          --pipeline NAME        Buildkite pipeline name (default: julia-master)
          --include-mechanical   Include mechanical jobs (upload, launch, etc.)
          -h, --help             Show this help message

        Environment variables:
          BUILDKITE_API_TOKEN    Required for API access

        Baseline data is loaded from the local database (data/timing_summary.json).

        Exit codes:
          0  No significant regressions
          1  Significant regressions detected
          2  Error
        """)
        return 0
    end

    build_number = parse(Int, args[1])
    baseline_commits = DEFAULT_BASELINE_COMMITS
    base_build = nothing  # If set, only use builds <= this number for baseline
    threshold_percent = 10.0
    output_json = false
    output_markdown = false
    pipeline = BUILDKITE_PIPELINE
    include_mechanical = false

    i = 2
    while i <= length(args)
        if args[i] == "--baseline-commits" && i < length(args)
            baseline_commits = parse(Int, args[i+1])
            i += 2
        elseif args[i] == "--base-build" && i < length(args)
            base_build = parse(Int, args[i+1])
            i += 2
        elseif args[i] == "--threshold" && i < length(args)
            threshold_percent = parse(Float64, args[i+1])
            i += 2
        elseif args[i] == "--json"
            output_json = true
            i += 1
        elseif args[i] == "--markdown"
            output_markdown = true
            i += 1
        elseif args[i] == "--pipeline" && i < length(args)
            pipeline = args[i+1]
            i += 2
        elseif args[i] == "--include-mechanical"
            include_mechanical = true
            i += 1
        else
            @warn "Unknown argument" arg=args[i]
            i += 1
        end
    end

    # Get API token
    token = try
        get_api_token()
    catch e
        println(stderr, "Error: ", e.msg)
        return 2
    end

    # Fetch current build
    if !output_json && !output_markdown
        println("Fetching build #$build_number...")
    end

    current_jobs = fetch_build_jobs(build_number, token; pipeline=pipeline)
    if current_jobs === nothing || isempty(current_jobs)
        println(stderr, "Error: Could not fetch jobs for build #$build_number")
        return 2
    end

    if !output_json && !output_markdown
        println("Found $(length(current_jobs)) jobs")
    end

    # Always fetch build info to extract PR number
    build_info = fetch_build_info(build_number, token; pipeline=pipeline)
    pr_number = build_info !== nothing ? build_info.pr_number : nothing

    # Auto-detect base build for PR branches if not explicitly set
    if base_build === nothing
        (detected_base, branch) = determine_base_build(build_number, token; pipeline=pipeline, quiet=output_json || output_markdown)
        if detected_base !== nothing
            base_build = detected_base
        end
    end

    # Load baseline from database
    if !output_json && !output_markdown
        if base_build !== nothing
            println("Loading baseline from database (last $baseline_commits builds up to #$base_build)...")
        else
            println("Loading baseline from database (last $baseline_commits builds)...")
        end
    end

    baseline_data = load_baseline_from_database(baseline_commits; pipeline=pipeline, max_build=base_build)
    if baseline_data === nothing || isempty(baseline_data)
        println(stderr, "Error: Could not load baseline data from database")
        return 2
    end

    if !output_json && !output_markdown
        println("Loaded baseline for $(length(baseline_data)) jobs")
    end

    # Compare
    results = compare_build(current_jobs, baseline_data; threshold_percent=threshold_percent, include_mechanical=include_mechanical)

    # Output results
    regressions = filter(r -> r.significant && r.regression, results)

    if output_json
        println(generate_json_output(results, build_number))
    elseif output_markdown
        println(generate_markdown_comment(results, build_number))
    else
        print_results(results; verbose=true)
        println("\nTotal jobs compared: $(length(results))")

        # Generate comparison URL for the website
        if !isempty(results) && base_build !== nothing
            url = generate_comparison_url(current_jobs, build_number, base_build; pr_number=pr_number)
            println("\n📊 View comparison on dashboard:")
            println("   $url")
        end
    end

    # Exit code based on regressions
    return isempty(regressions) ? 0 : 1
end

exit(main())
