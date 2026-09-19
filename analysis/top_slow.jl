#!/usr/bin/env julia
# List the slowest N benchmarks per group (after stripping BigInt/BigFloat,
# which dominate trivially because of GMP).
#
# Usage:
#   julia --project=.. top_slow.jl array            # top 25 slowest in array
#   julia --project=.. top_slow.jl array 50         # top 50
#   julia --project=.. top_slow.jl --all 10         # top 10 of every group

using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
include(joinpath(@__DIR__, "BenchHistory.jl"))
using .BenchHistory

function print_top(group, n)
    d = load_group(group)
    out = Tuple{String,Float64}[]
    for (k, v) in pairs(d.minimum.benchmarks)
        s = String(k)
        occursin("Big", s) && continue
        rm = recent_minimum(v)
        isnan(rm) && continue
        push!(out, (s, rm))
    end
    sort!(out, by = x -> -x[2])
    println("\n=== $group  (top $n) ===")
    for (k, t) in first(out, n)
        println(rpad(k, 100), " ", round(t, digits=0), "ns")
    end
end

if !isempty(ARGS) && ARGS[1] == "--all"
    n = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 10
    for g in BenchHistory.all_groups()
        print_top(g, n)
    end
else
    isempty(ARGS) && error("usage: top_slow.jl <group> [n]   |   top_slow.jl --all [n]")
    group = ARGS[1]
    n = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 25
    print_top(group, n)
end
