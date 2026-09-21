#!/usr/bin/env julia
# Structural comparison of two data directories: the committed data/ against
# what db/export.jl rendered from the database.
#
#   julia --project db/compare.jl REFERENCE_DIR EXPORT_DIR
#
# Ignores `generated_at`, compares numbers by value (11 == 11.0, floats to
# 1e-9 relative), and reports
# arrays that differ only in element order separately from real
# differences. Exit 1 on any real difference or missing file.

using Pkg
Pkg.activate(dirname(@__DIR__); io=devnull)

using JSON3, CodecZlib

# JSON3 values to plain Dict/Vector so the recursion below is simple.
tojulia(x::JSON3.Object) = Dict{String,Any}(String(k) => tojulia(v) for (k, v) in x)
tojulia(x::JSON3.Array) = Any[tojulia(v) for v in x]
tojulia(x) = x

function load(path)
    if endswith(path, ".json.gz")
        return tojulia(JSON3.read(transcode(GzipDecompressor, read(path))))
    elseif endswith(path, ".ndjson")
        return Any[tojulia(JSON3.read(l)) for l in eachline(path) if !isempty(strip(l))]
    else
        return tojulia(JSON3.read(read(path)))
    end
end

const IGNORED_KEYS = Set(["generated_at"])
const MAX_REPORTS = 12

mutable struct Report
    diffs::Int
    order_only::Int
    lines::Vector{String}
end
Report() = Report(0, 0, String[])

function note!(rep, path, msg; order=false)
    if order
        rep.order_only += 1
    else
        rep.diffs += 1
    end
    length(rep.lines) < MAX_REPORTS && push!(rep.lines, "$(order ? "order" : "DIFF") $path: $msg")
end

isnum(x) = x isa Number && !(x isa Bool)

function compare!(rep, a, b, path)
    if isnum(a) && isnum(b)
        # Computed floats (geomeans, stats) may differ in the last digits
        # with the summation order; that is not a data difference
        isapprox(a, b; rtol=1e-9) || note!(rep, path, "$a != $b")
    elseif a isa Dict && b isa Dict
        for k in union(keys(a), keys(b))
            k in IGNORED_KEYS && continue
            if !haskey(a, k)
                note!(rep, "$path.$k", "only in export")
            elseif !haskey(b, k)
                note!(rep, "$path.$k", "missing from export")
            else
                compare!(rep, a[k], b[k], "$path.$k")
            end
        end
    elseif a isa Vector && b isa Vector
        if length(a) != length(b)
            note!(rep, path, "length $(length(a)) != $(length(b))")
            return
        end
        sub = Report()
        for i in eachindex(a)
            compare!(sub, a[i], b[i], "$path[$i]")
        end
        if sub.diffs == 0
            rep.order_only += sub.order_only
            append!(rep.lines, sub.lines[1:min(end, MAX_REPORTS - length(rep.lines))])
        else
            # Same multiset in a different order is an ordering difference
            key(x) = JSON3.write(x isa Dict ? sort(collect(x); by=first) : x)
            if sort(key.(a)) == sort(key.(b))
                note!(rep, path, "same elements, different order"; order=true)
            else
                rep.diffs += sub.diffs
                rep.order_only += sub.order_only
                append!(rep.lines, sub.lines[1:min(end, MAX_REPORTS - length(rep.lines))])
            end
        end
    else
        a == b || note!(rep, path, "$(repr(a)) != $(repr(b))")
    end
end

function relative_files(dir)
    files = String[]
    for (root, _, names) in walkdir(dir)
        for n in names
            (endswith(n, ".json") || endswith(n, ".json.gz") || endswith(n, ".ndjson")) || continue
            n in ("ttfx_annotations.json", "methodology_changes.json") && continue   # hand-maintained, not exported
            push!(files, relpath(joinpath(root, n), dir))
        end
    end
    return sort(files)
end

function main(args)
    length(args) == 2 || error("usage: compare.jl REFERENCE_DIR EXPORT_DIR")
    ref, exp = args
    failed = 0
    for f in relative_files(ref)
        e = joinpath(exp, f)
        if !isfile(e)
            println("MISSING $f")
            failed += 1
            continue
        end
        rep = Report()
        compare!(rep, load(joinpath(ref, f)), load(e), f)
        status = rep.diffs == 0 ? (rep.order_only == 0 ? "ok" : "ok (order only: $(rep.order_only))") : "FAIL ($(rep.diffs) differences)"
        println(rpad(f, 45), status)
        foreach(l -> println("    ", l), rep.lines)
        rep.diffs == 0 || (failed += 1)
    end
    for f in relative_files(exp)
        isfile(joinpath(ref, f)) || println("EXTRA   $f")
    end
    exit(failed == 0 ? 0 : 1)
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
