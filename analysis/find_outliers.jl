#!/usr/bin/env julia
# Print benchmark variants that are >5x slower than their family median.
# Useful for spotting type-specialization regressions and codegen sensitivity.
#
# Usage:
#   julia --project=.. find_outliers.jl                # default thresholds
#   julia --project=.. find_outliers.jl --ratio 10 --min-ns 500
#   julia --project=.. find_outliers.jl --groups array,union,scalar

using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
include(joinpath(@__DIR__, "BenchHistory.jl"))
using .BenchHistory

ratio = 5.0
min_ns = 100.0
groups = BenchHistory.all_groups()
limit = 60

let i = 1
    while i <= length(ARGS)
        a = ARGS[i]
        if a == "--ratio";  global ratio = parse(Float64, ARGS[i+1]); i += 2
        elseif a == "--min-ns"; global min_ns = parse(Float64, ARGS[i+1]); i += 2
        elseif a == "--groups"; global groups = String.(split(ARGS[i+1], ',')); i += 2
        elseif a == "--limit"; global limit = parse(Int, ARGS[i+1]); i += 2
        else; error("unknown arg $a")
        end
    end
end

outs = find_family_outliers(; ratio=ratio, min_time_ns=min_ns, groups=groups)
println("Found $(length(outs)) outliers (>$(ratio)x family median, time>$(min_ns)ns)\n")
for o in first(outs, limit)
    println(rpad("$(o.group)/$(o.bench)", 100),
            "  ", rpad(string(round(o.time, digits=1), "ns"), 12),
            " fam_med=", round(o.family_median, digits=1), "ns",
            "  ratio=", round(o.ratio, digits=1), "x")
end
