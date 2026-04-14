#!/usr/bin/env julia
# Fetch Julia Base benchmark reports from NanosoldierReports
# Clones the repo (sparse checkout of benchmark/by_date) and extracts raw timing
# data from data.tar.zst files, computing per-group geometric mean times.

using JSON3
using Dates
using Statistics
using DataStructures: SortedDict
using CodecZstd
using Tar

const REPORTS_REPO = "https://github.com/JuliaCI/NanosoldierReports.git"
const CLONE_DIR = joinpath(tempdir(), "NanosoldierReports")

function ensure_clone()
    by_date = joinpath(CLONE_DIR, "benchmark", "by_date")
    if isdir(joinpath(CLONE_DIR, ".git"))
        @info "Updating existing clone..." dir=CLONE_DIR
        run(`git -C $CLONE_DIR pull --ff-only`)
    else
        @info "Cloning NanosoldierReports (sparse)..." dir=CLONE_DIR
        rm(CLONE_DIR; force=true, recursive=true)
        run(`git clone --depth 1 --filter=blob:none --sparse $REPORTS_REPO $CLONE_DIR`)
        run(`git -C $CLONE_DIR sparse-checkout set benchmark/by_date`)
    end
    isdir(by_date) || error("benchmark/by_date not found after clone")
    return by_date
end

function enumerate_report_dates(by_date_dir::String)
    @info "Enumerating benchmark report dates..."
    dates = String[]
    for month in readdir(by_date_dir; sort=true)
        month_path = joinpath(by_date_dir, month)
        isdir(month_path) || continue
        for day in readdir(month_path; sort=true)
            day_path = joinpath(month_path, day)
            isdir(day_path) || continue
            push!(dates, "$month/$day")
        end
    end
    @info "Found $(length(dates)) benchmark reports"
    return dates
end

function date_path_to_date(path::String)
    parts = split(path, "/")
    "$(parts[1])-$(lpad(parts[2], 2, '0'))"
end

"""
Walk a BenchmarkTools JSON structure and collect all leaf `time` values per top-level group.
The structure is: [metadata, [[\"BenchmarkGroup\", {\"data\": {group => ...}}]]]
"""
function collect_group_times(parsed)
    result = Dict{String, Vector{Float64}}()

    data_root = parsed[2][1][2]["data"]
    for (group_name, group_node) in data_root
        times = Float64[]
        walk_times!(times, group_node)
        if !isempty(times)
            result[String(group_name)] = times
        end
    end
    return result
end

function walk_times!(times::Vector{Float64}, node)
    node isa AbstractVector && length(node) == 2 || return
    tag = node[1]
    tag isa AbstractString || return
    if tag == "TrialEstimate"
        t = get(node[2], "time", nothing)
        t !== nothing && push!(times, Float64(t))
    elseif tag == "BenchmarkGroup"
        for (_, child) in get(node[2], "data", Dict())
            walk_times!(times, child)
        end
    end
end

function geomean(xs)
    isempty(xs) && return 0.0
    exp(mean(log, xs))
end

function extract_commit(by_date_dir::String, date_path::String)
    report_file = joinpath(by_date_dir, date_path, "report.md")
    isfile(report_file) || return ""
    for line in eachline(report_file)
        m = match(r"JuliaLang/julia@([0-9a-f]+)", line)
        m !== nothing && return String(m.captures[1])[1:min(8, length(m.captures[1]))]
    end
    return ""
end

function parse_tarball(by_date_dir::String, date_path::String)
    date = date_path_to_date(date_path)
    tarball = joinpath(by_date_dir, date_path, "data.tar.zst")
    isfile(tarball) || return nothing

    commit = extract_commit(by_date_dir, date_path)

    # Extract into a temp directory
    tmpdir = mktempdir()
    try
        open(tarball) do io
            stream = ZstdDecompressorStream(io)
            Tar.extract(stream, tmpdir)
            close(stream)
        end
    catch e
        @warn "Failed to extract tarball" date_path error=e
        rm(tmpdir; recursive=true, force=true)
        return nothing
    end

    by_group = SortedDict{String, Any}()

    for stat_type in ("minimum", "mean")
        json_files = filter(f -> endswith(f, "_primary.$stat_type.json"), readdir(tmpdir))
        isempty(json_files) && continue
        json_path = joinpath(tmpdir, json_files[1])

        local parsed
        try
            parsed = JSON3.read(read(json_path, String); allow_inf=true)
        catch e
            @warn "Failed to parse JSON" date_path stat_type error=e
            continue
        end

        group_times = collect_group_times(parsed)
        for (group, times) in group_times
            if !haskey(by_group, group)
                by_group[group] = Dict{String, Any}()
            end
            by_group[group]["$(stat_type)_geomean_ns"] = geomean(times)
            by_group[group]["$(stat_type)_count"] = length(times)
        end
    end

    rm(tmpdir; recursive=true, force=true)

    isempty(by_group) && return nothing

    return SortedDict(
        "date" => date,
        "commit" => commit,
        "by_group" => by_group,
    )
end

function load_existing_data(output_dir)
    summary_file = joinpath(output_dir, "benchmark_summary.json")
    !isfile(summary_file) && return Dict{String, Any}()
    try
        data = JSON3.read(read(summary_file, String))
        @info "Loaded existing benchmark data" reports=length(get(data, :reports, []))
        return data
    catch e
        @warn "Failed to load existing benchmark data, starting fresh" error=e
        return Dict{String, Any}()
    end
end

function get_known_dates(existing_data)
    dates = Set{String}()
    for report in get(existing_data, :reports, [])
        d = get(report, :date, nothing)
        d !== nothing && push!(dates, String(d))
    end
    return dates
end

function generate_json_output(new_reports, existing_data; output_dir="data")
    mkpath(output_dir)

    reports_by_date = SortedDict{String, Any}()

    for report in get(existing_data, :reports, [])
        d = String(get(report, :date, ""))
        isempty(d) && continue
        reports_by_date[d] = SortedDict(
            "date" => d,
            "commit" => String(get(report, :commit, "")),
            "by_group" => let bg = get(report, :by_group, Dict())
                SortedDict{String, Any}(String(k) => Dict{String, Any}(
                    String(fk) => fv for (fk, fv) in pairs(v)
                ) for (k, v) in pairs(bg))
            end
        )
    end

    for report in new_reports
        reports_by_date[report["date"]] = report
    end

    reports = [reports_by_date[k] for k in sort(collect(keys(reports_by_date)))]

    summary = SortedDict(
        "generated_at" => Dates.format(now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SSZ"),
        "reports" => reports
    )

    summary_file = joinpath(output_dir, "benchmark_summary.json")

    if isfile(summary_file)
        existing_content = read(summary_file, String)
        existing_parsed = JSON3.read(existing_content)
        existing_reports_json = sprint(io -> JSON3.pretty(io, get(existing_parsed, :reports, [])))
        new_reports_json = sprint(io -> JSON3.pretty(io, reports))
        if existing_reports_json == new_reports_json
            @info "No changes to benchmark data, skipping write"
            return summary_file
        end
    end

    open(summary_file, "w") do f
        JSON3.pretty(f, summary)
    end
    @info "Wrote benchmark summary" file=summary_file num_reports=length(reports)
    return summary_file
end

function main()
    by_date_dir = ensure_clone()

    existing = load_existing_data("data")
    known_dates = get_known_dates(existing)
    @info "Known dates" count=length(known_dates)

    all_dates = enumerate_report_dates(by_date_dir)

    new_dates = filter(d -> date_path_to_date(d) ∉ known_dates, all_dates)
    @info "New reports to parse" count=length(new_dates)

    new_reports = []
    for (i, date_path) in enumerate(new_dates)
        @info "Parsing report $i/$(length(new_dates)): $date_path"
        report = parse_tarball(by_date_dir, date_path)
        if report !== nothing
            push!(new_reports, report)
        else
            @warn "No data extracted" date_path
        end
    end

    @info "Parsed new reports" count=length(new_reports)

    generate_json_output(new_reports, existing)
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
