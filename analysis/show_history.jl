#!/usr/bin/env julia
# Print the time series for one or more benchmarks alongside the commit
# hash, so a regression can be bisected.
#
# Usage:
#   julia --project=.. show_history.jl array "index/('sumlinear_view', 'Matrix{Int64}')"
#   julia --project=.. show_history.jl array "sub2ind"        # substring match

using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
include(joinpath(@__DIR__, "BenchHistory.jl"))
using .BenchHistory

length(ARGS) >= 2 || error("usage: show_history.jl <group> <bench-substring> [stat]")
group = ARGS[1]
needle = ARGS[2]
stat = length(ARGS) >= 3 ? Symbol(ARGS[3]) : :minimum

d = load_group(group)
node = d[stat]
matches = [String(k) for k in keys(node.benchmarks) if occursin(needle, String(k))]
isempty(matches) && error("no benchmark in group $group matches '$needle'")

dates = node.dates
commits = node.commits
for m in matches
    println("=== $group/$m  ($(stat)) ===")
    series = node.benchmarks[Symbol(m)]
    prev = nothing
    for i in eachindex(series)
        v = series[i]
        v === nothing && continue
        v <= 0 && continue
        date = dates[i]
        commit = String(commits[i])[1:min(10, end)]
        change = ""
        if prev !== nothing && prev > 0
            r = v / prev
            (r > 1.10 || r < 0.91) &&
                (change = string(" (", r > 1 ? "+" : "", round(100*(r-1), digits=1), "%)"))
        end
        println(rpad(date, 12), " ", rpad(commit, 12),
                " ", lpad(string(round(Float64(v), digits=1)), 14), "ns", change)
        prev = v
    end
    println()
end
