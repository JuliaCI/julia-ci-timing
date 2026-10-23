#!/usr/bin/env julia
# Run fetchers one after another in a single Julia process, so the packages are
# loaded and the code the fetchers share is compiled once per ingest rather
# than once per fetcher. On the host each fresh process spent 7 to 18 seconds
# compiling before its first request.
#
#   julia --project db/ingest.jl [--db PATH] [--progress FILE] [--timeout MINUTES] fetch_timing.jl ...
#
# Each fetcher is loaded into a module of its own, since they define the same
# names (`main`, `run!`, ...). One that fails is logged and the next one runs.
# Before a fetcher starts, its name is added as a line to the progress file. A
# fetcher still running after --timeout minutes (30 by default) ends the whole
# process: the caller (infra/docker/entrypoint.sh) then starts it again with
# the fetchers that had not started.

using CITiming

const ROOT = dirname(@__DIR__)

function parse_args(args)
    opts = Dict{String,Any}("db" => nothing, "progress" => nothing, "timeout" => 30.0, "files" => String[])
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("--db", "--progress", "--timeout")
            opts[a[3:end]] = a == "--timeout" ? parse(Float64, args[i+1]) : args[i+1]
            i += 2
        else
            push!(opts["files"], a)
            i += 1
        end
    end
    return opts
end

function main(args)
    opts = parse_args(args)
    fetcher_args = opts["db"] === nothing ? String[] : ["--db", opts["db"]]
    failed = false
    for file in opts["files"]
        opts["progress"] === nothing || open(io -> println(io, file), opts["progress"], "a")
        println("==> $file")
        flush(stdout)
        # The time limit is kept by another process: a task in this one would not
        # run while the fetcher is blocked in a C call
        msg = "!! $file is still running after $(opts["timeout"]) minutes; stopping"
        secs = round(Int, 60 * opts["timeout"])
        # The trap ends the sleep with it, which would otherwise hold this process's output open
        script = "trap 'kill \$! 2>/dev/null; exit 0' TERM; sleep $secs & wait \$!; echo '$msg' >&2; kill -KILL $(getpid())"
        watchdog = run(pipeline(`sh -c $script`; stdout, stderr); wait=false)
        try
            # Not the bare file name: fetch_agents.jl defines a function of that name
            name = Symbol("Run_", replace(splitext(basename(file))[1], r"\W" => "_"))
            m = Core.eval(Main, Expr(:module, true, name, Expr(:block)))
            Base.include(m, joinpath(ROOT, file))
            code = Base.invokelatest(m -> getglobal(m, :main)(fetcher_args), m)
            code == 0 || (failed = true; println(stderr, "!! $file failed"))
        catch e
            @error "$file failed" exception=(e, catch_backtrace())
            println(stderr, "!! $file failed")
            failed = true
        finally
            kill(watchdog)
        end
    end
    return failed ? 1 : 0
end

abspath(PROGRAM_FILE) == (@__FILE__) && exit(main(ARGS))
