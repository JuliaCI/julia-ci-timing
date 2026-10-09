# Size measurements of an unpacked Julia distribution, for fetch_sizes.jl and for
# seeding the history from other builds. No package dependencies, so it also runs
# standalone on any Julia >= 1.6:
#
#   julia tools/measure_sizes.jl <root> [<root>...]
#
# prints `root \t kind \t key \t bytes` lines: kind is `metric` for the fixed set of
# measurements (see `measure`) and `file` for every file of at least FILE_MIN bytes,
# for attributing a jump to the files that grew (see `group_files`).
module SizeMeasure

const FILE_MIN = 1 << 20

## ELF

struct Section
    name::String
    type::UInt32
    flags::UInt64
    offset::UInt64
    size::UInt64
    link::UInt32
    entsize::UInt64
end

const SHT_SYMTAB = 2
const SHT_NOBITS = 8
const SHT_DYNSYM = 11
const SHF_COMPRESSED = 0x800

iself(path) = filesize(path) >= 64 && open(io -> read(io, 4), path) == b"\x7fELF"

function cstring(buf::Vector{UInt8}, i::Integer)
    j = findnext(iszero, buf, i + 1)
    return String(buf[i+1:j-1])
end

function elf_sections(io::IO)
    seek(io, 0)
    hdr = read(io, 64)
    hdr[5] == 2 || error("not a 64-bit ELF file")   # ELFCLASS64
    hdr[6] == 1 || error("not a little-endian ELF file")
    ld(T, off) = reinterpret(T, hdr[off+1:off+sizeof(T)])[1]
    shoff = ld(UInt64, 0x28)
    shentsize = ld(UInt16, 0x3a)
    shnum = ld(UInt16, 0x3c)
    shstrndx = ld(UInt16, 0x3e)
    seek(io, shoff)
    raw = read(io, Int(shentsize) * shnum)
    rd(T, i, off) = reinterpret(T, raw[(i*shentsize+off)+1:(i*shentsize+off)+sizeof(T)])[1]
    strtab_off = rd(UInt64, shstrndx, 24)
    strtab_size = rd(UInt64, shstrndx, 32)
    seek(io, strtab_off)
    names = read(io, strtab_size)
    return [Section(cstring(names, rd(UInt32, i, 0)), rd(UInt32, i, 4), rd(UInt64, i, 8),
                    rd(UInt64, i, 24), rd(UInt64, i, 32), rd(UInt32, i, 40), rd(UInt64, i, 56))
            for i in 0:shnum-1]
end

# size of the named symbol in the static or dynamic symbol table, or `nothing`
function elf_symbol_size(io::IO, secs::Vector{Section}, name::String)
    target = Vector{UInt8}(name)
    for sec in secs
        sec.type in (SHT_SYMTAB, SHT_DYNSYM) || continue
        strsec = secs[sec.link+1]
        seek(io, strsec.offset)
        strs = read(io, strsec.size)
        seek(io, sec.offset)
        syms = read(io, sec.size)
        for i in 0:div(sec.size, 24)-1
            off = Int(reinterpret(UInt32, syms[i*24+1:i*24+4])[1])
            off + length(target) < length(strs) || continue
            strs[off+length(target)+1] == 0x00 || continue
            view(strs, off+1:off+length(target)) == target || continue
            return Int(reinterpret(UInt64, syms[i*24+17:i*24+24])[1])
        end
    end
    return nothing
end

# file bytes of an ELF file by section class
function elf_breakdown(path)
    out = Dict("text" => 0, "rodata" => 0, "data" => 0, "dwarf" => 0, "symtab" => 0,
               "dynsym" => 0, "other" => 0)
    open(path) do io
        secs = elf_sections(io)
        for s in secs
            s.type == SHT_NOBITS && continue
            n = s.name
            class = if n == ".text"
                "text"
            elseif startswith(n, ".rodata")
                "rodata"
            elseif startswith(n, ".data") || n == ".ldata" || n == ".lrodata"
                "data"
            elseif startswith(n, ".debug_") || startswith(n, ".zdebug_")
                "dwarf"
            elseif n in (".symtab", ".strtab")
                "symtab"
            elseif n in (".dynsym", ".dynstr", ".gnu.hash", ".hash")
                "dynsym"
            else
                "other"
            end
            out[class] += Int(s.size)
        end
        out["image_data"] = something(elf_symbol_size(io, secs, "jl_system_image_data"), 0)
    end
    return out
end

## tree walking

# regular files under `root` (symlinks skipped), as relative path => size
function file_sizes(root)
    files = Dict{String,Int}()
    for (dir, _, fs) in walkdir(root)
        for f in fs
            p = joinpath(dir, f)
            islink(p) && continue
            isfile(p) || continue
            files[relpath(p, root)] = filesize(p)
        end
    end
    return files
end

sumwhere(pred, files) = sum((v for (k, v) in files if pred(k)); init=0)

function measure(root)
    files = file_sizes(root)
    m = Dict{String,Int}()
    m["total"] = sum(values(files); init=0)
    m["files"] = length(files)
    for top in unique(first(splitpath(k)) for k in keys(files))
        m["dir.$top"] = sumwhere(k -> first(splitpath(k)) == top, files)
    end
    for d in ("base", "stdlib", "compiled", "test")
        p = joinpath("share", "julia", d)
        m["share.$d"] = sumwhere(k -> startswith(k, p * "/"), files)
    end

    # runtime and sysimage
    libjulia = joinpath("lib", "julia")
    isprefix(k, name) = dirname(k) == libjulia && startswith(basename(k), name)
    groups = [
        "sysimg" => k -> k == joinpath(libjulia, "sys.so"),
        "libjulia-internal" => k -> isprefix(k, "libjulia-internal"),
        "libjulia-codegen" => k -> isprefix(k, "libjulia-codegen"),
        "libLLVM" => k -> isprefix(k, "libLLVM"),
        "libjulia" => k -> dirname(k) == "lib" && startswith(basename(k), "libjulia."),
    ]
    for (name, pred) in groups
        ks = filter(pred, collect(keys(files)))
        m[name] = sum(files[k] for k in ks; init=0)
        for k in ks
            iself(joinpath(root, k)) || continue
            for (class, n) in elf_breakdown(joinpath(root, k))
                (class == "image_data" && name != "sysimg") && continue
                key = "$name.$class"
                m[key] = get(m, key, 0) + n
            end
        end
    end
    grouped = mapreduce(last, (a, b) -> k -> a(k) || b(k), groups)
    m["libs.other"] = sumwhere(k -> dirname(k) == libjulia && !grouped(k), files)
    # DWARF in the other bundled libraries (JLLs etc.)
    m["libs.other.dwarf"] = 0
    for k in keys(files)
        dirname(k) == libjulia && !grouped(k) && occursin(r"\.so(\.|$)", basename(k)) || continue
        iself(joinpath(root, k)) || continue
        m["libs.other.dwarf"] += elf_breakdown(joinpath(root, k))["dwarf"]
    end

    # stdlib pkgimages
    compiled = joinpath("share", "julia", "compiled") * "/"
    m["pkgimg.ji"] = sumwhere(k -> startswith(k, compiled) && endswith(k, ".ji"), files)
    m["pkgimg.so"] = sumwhere(k -> startswith(k, compiled) && endswith(k, ".so"), files)
    m["pkgimg.count"] = count(k -> startswith(k, compiled) && endswith(k, ".ji"), keys(files))
    m["pkgimg.so.dwarf"] = 0
    for k in keys(files)
        startswith(k, compiled) && endswith(k, ".so") || continue
        iself(joinpath(root, k)) || continue
        m["pkgimg.so.dwarf"] += elf_breakdown(joinpath(root, k))["dwarf"]
    end

    big = group_files(Dict(k => v for (k, v) in files if v >= FILE_MIN))
    return m, big
end

# Pkgimage names carry a hash that changes with every build, so a package's images
# are summed per extension under `<package dir>/*.ji` and `*.so` to keep their keys
# comparable across commits. Idempotent.
function group_files(files)
    out = Dict{String,Int}()
    for (k, v) in files
        key = replace(k, r"^(share/julia/compiled/[^/]+/[^/]+)/[^/]+\.(ji|so|dylib|dll)$" => s"\1/*.\2")
        out[key] = get(out, key, 0) + v
    end
    return out
end

# The distribution's version as `VERSION` shows it: JULIA_VERSION_STRING from
# julia_version.h, with a prerelease's build number (the commits since VERSION
# last changed) from base/version_git.jl appended, as in 1.14.0-DEV.3551
function version(root)
    h = joinpath(root, "include", "julia", "julia_version.h")
    isfile(h) || return ""
    m = match(r"#define JULIA_VERSION_STRING \"([^\"]*)\"", read(h, String))
    m === nothing && return ""
    v = String(m.captures[1])
    g = joinpath(root, "share", "julia", "base", "version_git.jl")
    if occursin('-', v) && isfile(g)
        # GitVersionInfo(commit, commit_short, branch, build_number, ...)
        b = match(r"GitVersionInfo\(\s*\"[^\"]*\",\s*\"[^\"]*\",\s*\"[^\"]*\",\s*(\d+)", read(g, String))
        b === nothing || b.captures[1] == "0" || (v *= "." * b.captures[1])
    end
    return v
end

function main(args)
    for root in args
        m, big = measure(root)
        for k in sort(collect(keys(m)))
            println(root, '\t', "metric", '\t', k, '\t', m[k])
        end
        for k in sort(collect(keys(big)))
            println(root, '\t', "file", '\t', k, '\t', big[k])
        end
    end
end

end # module

abspath(PROGRAM_FILE) == (@__FILE__) && SizeMeasure.main(ARGS)
