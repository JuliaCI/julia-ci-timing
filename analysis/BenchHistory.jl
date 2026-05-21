#!/usr/bin/env julia
# Helpers for analyzing aggregated BaseBenchmarks history stored in
# `data/benchmarks/<group>.json.gz`.
#
# Each gzipped JSON has the shape:
#   { "minimum": { benchmarks: {name => [t1, t2, ...]},
#                  dates:      [...],
#                  date_paths: [...],
#                  commits:    [...] },
#     "mean":    { ... same shape ... } }
#
# Times are in nanoseconds. `nothing` entries mean "benchmark not present
# on that date". The vectors are aligned with `dates`/`commits` so you can
# correlate a regression to a specific commit.

module BenchHistory

using JSON3
using CodecZlib
using Statistics

export load_group, all_groups, recent_minimum, noise_pct,
       all_benches, family_key, find_family_outliers

const DATA_DIR = abspath(joinpath(@__DIR__, "..", "data", "benchmarks"))

const KNOWN_GROUPS = ["alloc","array","broadcast","collection","dates","find",
                      "frontend","inference","io","linalg","micro","misc",
                      "parallel","problem","random","scalar","shootout","simd",
                      "sort","sparse","string","tuple","union"]

all_groups() = [g for g in KNOWN_GROUPS if isfile(joinpath(DATA_DIR, "$g.json.gz"))]

function load_group(name::AbstractString)
    path = joinpath(DATA_DIR, "$name.json.gz")
    open(path) do io
        JSON3.read(transcode(GzipDecompressor, read(io)))
    end
end

# Extract clean Float64 vector from a stored series (drops nothing/0).
function clean_times(v)
    Float64[Float64(x) for x in v if x !== nothing && x > 0]
end

"Minimum of the last `n` valid times in the series."
function recent_minimum(v; n::Int = 10)
    t = clean_times(v)
    isempty(t) && return NaN
    minimum(@view t[max(1, end-n+1):end])
end

"Run-to-run noise in % over the last `n` valid samples (median |Δlog|)."
function noise_pct(v; n::Int = 20)
    t = clean_times(v)
    length(t) < 3 && return NaN
    last_n = @view t[max(1, end-n+1):end]
    100 * median(abs.(diff(log.(last_n))))
end

"""
    all_benches([groups]; stat=:minimum)

Iterate (group, bench_name, series::Vector) over every benchmark in the given
groups (or all known groups). The series is the raw vector from disk (may
contain `nothing`).
"""
function all_benches(groups = all_groups(); stat::Symbol = :minimum)
    Channel{Tuple{String, String, Any}}() do ch
        for g in groups
            d = try load_group(g) catch; continue end
            haskey(d, stat) || continue
            benches = d[stat].benchmarks
            for (k, v) in pairs(benches)
                put!(ch, (g, String(k), v))
            end
        end
    end
end

# ---- Family analysis: find one variant much slower than its siblings ----

const _TYPE_TOKENS = (
    "Bool","Int8","Int16","Int32","Int64","Int128","UInt8","UInt16","UInt32",
    "UInt64","UInt128","Float16","Float32","Float64","BigFloat","BigInt",
    "ComplexF16","ComplexF32","ComplexF64","Char","String","Symbol",
)

"""
    family_key(name) -> String

Strip type names and integer sizes so that variants of the same benchmark
(only differing in element type / size) produce the same key.
"""
function family_key(name::AbstractString)
    s = String(name)
    for t in _TYPE_TOKENS
        s = replace(s, "'$t'" => "'TYPE'")
        s = replace(s, "Union{Missing, $t}" => "UM")
        s = replace(s, "Union{Nothing, $t}" => "UN")
    end
    replace(s, r"\b\d{2,}\b" => "N")
end

"""
    find_family_outliers(; ratio=5.0, min_time_ns=100, min_family_size=3, groups=all_groups())

Return Vector of NamedTuples for benchmarks that are `ratio`× slower than
the median of their family (same `family_key`). Useful for spotting type
specializations that didn't optimize as well as their siblings.
"""
function find_family_outliers(; ratio::Real = 5.0,
                              min_time_ns::Real = 100,
                              min_family_size::Int = 3,
                              groups = all_groups())
    fams = Dict{String, Vector{NamedTuple}}()
    for (g, name, v) in all_benches(groups)
        rm = recent_minimum(v)
        isnan(rm) && continue
        fk = string(g, '|', family_key(name))
        push!(get!(fams, fk, NamedTuple[]),
              (group=g, bench=name, time=rm))
    end
    out = NamedTuple[]
    for (_, members) in fams
        length(members) >= min_family_size || continue
        ts = [m.time for m in members]
        med = median(ts); mn = minimum(ts)
        mn < 1 && continue
        for m in members
            if m.time > ratio * med && m.time > min_time_ns
                push!(out, (m..., family_median=med, family_min=mn,
                            ratio=m.time / med))
            end
        end
    end
    sort!(out, by = x -> -x.ratio)
    return out
end

end # module
