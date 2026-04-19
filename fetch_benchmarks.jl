#!/usr/bin/env julia
# Fetch Julia Base benchmark reports from NanosoldierReports
# Clones the repo (sparse checkout of benchmark/by_date) and extracts raw timing
# data from data.tar.zst files, computing per-group geometric mean times.

using JSON3
using Dates
using Statistics
using DataStructures: SortedDict
using CodecZstd
using CodecZlib: GzipCompressor, GzipDecompressor
using Tar

const REPORTS_REPO = "https://github.com/JuliaCI/NanosoldierReports.git"
const CLONE_DIR = joinpath(tempdir(), "NanosoldierReports")

function ensure_clone()
    by_date = joinpath(CLONE_DIR, "benchmark", "by_date")
    if isdir(joinpath(CLONE_DIR, ".git"))
        @info "Updating existing clone..." dir=CLONE_DIR
        run(`git -C $CLONE_DIR fetch --depth 1 origin`)
        run(`git -C $CLONE_DIR reset --hard origin/master`)
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
Returns Dict{group_name => Dict{benchmark_path => time_ns}}
"""
function collect_group_times(parsed)
    result = Dict{String, Dict{String, Float64}}()

    data_root = parsed[2][1][2]["data"]
    for (group_name, group_node) in data_root
        benchmarks = Dict{String, Float64}()
        walk_times!(benchmarks, group_node, String[])
        if !isempty(benchmarks)
            result[String(group_name)] = benchmarks
        end
    end
    return result
end

function walk_times!(benchmarks::Dict{String, Float64}, node, path::Vector{String})
    node isa AbstractVector && length(node) == 2 || return
    tag = node[1]
    tag isa AbstractString || return
    if tag == "TrialEstimate"
        t = get(node[2], "time", nothing)
        if t !== nothing
            key = join(path, "/")
            benchmarks[key] = Float64(t)
        end
    elseif tag == "BenchmarkGroup"
        for (name, child) in get(node[2], "data", Dict())
            walk_times!(benchmarks, child, [path; replace(String(name), '"' => '\'')])
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
        for (group, benchmarks) in group_times
            if !haskey(by_group, group)
                by_group[group] = Dict{String, Any}()
            end
            times = collect(values(benchmarks))
            by_group[group]["$(stat_type)_geomean_ns"] = geomean(times)
            by_group[group]["$(stat_type)_count"] = length(times)
            by_group[group]["$(stat_type)_benchmarks"] = SortedDict{String, Any}(
                k => v for (k, v) in benchmarks
            )
        end
    end

    rm(tmpdir; recursive=true, force=true)

    isempty(by_group) && return nothing

    return SortedDict(
        "date" => date,
        "date_path" => date_path,
        "commit" => commit,
        "by_group" => by_group,
    )
end

function load_existing_data(output_dir)
    summary_gz = joinpath(output_dir, "benchmark_summary.json.gz")
    summary_file = joinpath(output_dir, "benchmark_summary.json")
    local summary
    try
        if isfile(summary_gz)
            summary = JSON3.read(transcode(GzipDecompressor, read(summary_gz)))
        elseif isfile(summary_file)
            summary = JSON3.read(read(summary_file, String))
        else
            return (nothing, Set{String}())
        end
    catch e
        @warn "Failed to load summary" error=e
        return (nothing, Set{String}())
    end

    reports = get(summary, :reports, [])
    @info "Loaded existing summary" reports=length(reports)

    # Check if per-group detail files exist — if not, need full re-parse
    benchdir = joinpath(output_dir, "benchmarks")
    has_detail = isdir(benchdir) && any(endswith(f, ".json") || endswith(f, ".json.gz") for f in readdir(benchdir))
    if !has_detail && !isempty(reports)
        @info "No per-group detail files found, forcing full re-parse"
        return (nothing, Set{String}())
    end

    known_dates = Set{String}()
    for report in reports
        d = get(report, :date, nothing)
        d !== nothing && push!(known_dates, String(d))
    end

    return (summary, known_dates)
end

function generate_json_output(new_reports, existing_summary; output_dir="data")
    mkpath(output_dir)
    mkpath(joinpath(output_dir, "benchmarks"))

    reports_by_date = SortedDict{String, Any}()

    if existing_summary !== nothing
        for report in get(existing_summary, :reports, [])
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
    end

    for report in new_reports
        reports_by_date[report["date"]] = report
    end

    reports = [reports_by_date[k] for k in sort(collect(keys(reports_by_date)))]

    # Build summary reports (geomean only, no _benchmarks)
    summary_reports = []
    for report in reports
        sr = SortedDict{String, Any}("date" => report["date"], "commit" => get(report, "commit", ""))
        sr_groups = SortedDict{String, Any}()
        for (group, gdata) in report["by_group"]
            sg = Dict{String, Any}()
            for (k, v) in gdata
                endswith(String(k), "_benchmarks") && continue
                sg[String(k)] = v
            end
            sr_groups[String(group)] = sg
        end
        sr["by_group"] = sr_groups
        push!(summary_reports, sr)
    end

    generated_at = Dates.format(now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SSZ")

    # Write per-group detail files (merge new data into existing)
    # Only new_reports have _benchmarks data; existing reports don't
    new_dates_with_benchmarks = filter(r -> any(
        endswith(String(k), "_benchmarks") for g in values(r["by_group"]) for k in keys(g)
    ), new_reports)

    if !isempty(new_dates_with_benchmarks)
        # Find all groups that have benchmark data in new reports
        groups_to_update = Set{String}()
        for report in new_dates_with_benchmarks
            for group in keys(report["by_group"])
                push!(groups_to_update, String(group))
            end
        end

        for group in sort(collect(groups_to_update))
            update_group_detail(output_dir, group, new_dates_with_benchmarks)
        end
    end

    # Write summary
    summary = SortedDict(
        "generated_at" => generated_at,
        "reports" => summary_reports
    )

    summary_file = joinpath(output_dir, "benchmark_summary.json")
    write_if_changed(summary_file, summary; gzip=true)

    return summary_file
end

function update_group_detail(output_dir, group, new_reports)
    group_file = joinpath(output_dir, "benchmarks", "$(group).json")
    group_file_gz = group_file * ".gz"

    # Load existing detail (prefer .json.gz, fall back to .json)
    existing = Dict{String, Any}()
    if isfile(group_file_gz)
        try
            existing = JSON3.read(transcode(GzipDecompressor, read(group_file_gz)))
        catch e
            @warn "Failed to load existing group detail, rebuilding" group error=e
        end
    elseif isfile(group_file)
        try
            existing = JSON3.read(read(group_file, String))
        catch e
            @warn "Failed to load existing group detail, rebuilding" group error=e
        end
    end

    for stat_type in ("minimum", "mean")
        # Load existing series
        old = get(existing, Symbol(stat_type), nothing)
        old_dates = old !== nothing ? [String(d) for d in old[:dates]] : String[]
        old_commits = old !== nothing ? [String(c) for c in old[:commits]] : String[]
        old_date_paths = old !== nothing && haskey(old, :date_paths) ? [String(p) for p in old[:date_paths]] : copy(old_dates)
        old_benchmarks = Dict{String, Vector{Any}}()
        if old !== nothing
            for (name, vals) in pairs(old[:benchmarks])
                old_benchmarks[String(name)] = collect(vals)
            end
        end

        old_date_set = Set(old_dates)

        # Collect new entries
        new_entries = []
        for report in new_reports
            report["date"] in old_date_set && continue
            gdata = get(report["by_group"], group, nothing)
            gdata === nothing && continue
            benchmarks = get(gdata, "$(stat_type)_benchmarks", nothing)
            benchmarks === nothing && continue
            push!(new_entries, (date=report["date"], date_path=get(report, "date_path", report["date"]), commit=get(report, "commit", ""), benchmarks=benchmarks))
        end

        isempty(new_entries) && continue

        # Collect all benchmark names
        all_names = Set(keys(old_benchmarks))
        for entry in new_entries
            for name in keys(entry.benchmarks)
                push!(all_names, String(name))
            end
        end
        sorted_names = sort(collect(all_names))

        # Pad existing series for any new benchmark names
        n_old = length(old_dates)
        merged_benchmarks = SortedDict{String, Vector{Any}}()
        for name in sorted_names
            if haskey(old_benchmarks, name)
                merged_benchmarks[name] = old_benchmarks[name]
            else
                merged_benchmarks[name] = fill(nothing, n_old)
            end
        end

        # Append new entries (sorted by date)
        sort!(new_entries; by=e -> e.date)
        merged_dates = copy(old_dates)
        merged_commits = copy(old_commits)
        merged_date_paths = copy(old_date_paths)
        for entry in new_entries
            push!(merged_dates, entry.date)
            push!(merged_commits, entry.commit)
            push!(merged_date_paths, entry.date_path)
            for name in sorted_names
                v = get(entry.benchmarks, name, nothing)
                push!(merged_benchmarks[name], v)
            end
        end

        existing_dict = existing isa Dict ? existing : Dict{String, Any}(String(k) => v for (k, v) in pairs(existing))
        existing_dict[stat_type] = SortedDict(
            "dates" => merged_dates,
            "date_paths" => merged_date_paths,
            "commits" => merged_commits,
            "benchmarks" => merged_benchmarks
        )
        existing = existing_dict
    end

    write_if_changed(group_file, SortedDict{String, Any}(String(k) => v for (k, v) in pairs(existing)); gzip=true)
end

function write_if_changed(filepath, data; gzip=false)
    new_json = JSON3.write(data)
    if gzip
        filepath = replace(filepath, r"\.json$" => ".json.gz")
        new_bytes = transcode(GzipCompressor, Vector{UInt8}(new_json))
        if isfile(filepath)
            existing = read(filepath)
            if existing == new_bytes
                @info "No changes, skipping write" file=filepath
                return
            end
        end
        write(filepath, new_bytes)
        @info "Wrote" file=filepath size=filesize(filepath)
    else
        if isfile(filepath)
            existing = read(filepath, String)
            if existing == new_json
                @info "No changes, skipping write" file=filepath
                return
            end
        end
        write(filepath, new_json)
        @info "Wrote" file=filepath size=filesize(filepath)
    end
end

function main()
    by_date_dir = ensure_clone()

    existing_summary, known_dates = load_existing_data("data")
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

    generate_json_output(new_reports, existing_summary)
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
