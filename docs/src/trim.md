# Trimmed binaries

`juliac --trim=safe` compiles a program to a small native binary by discarding everything it
cannot prove is reachable. It refuses to build if any call cannot be resolved statically, which
rules out most of what a dynamic file reader normally does. MAT73.jl is written to survive it,
and that constraint shapes the API.

## Using it

The entry point must define `@main` at top level — `juliac` includes the file into `Main`, and
a module wrapper is only allowed for a package entry:

```julia
using MAT73

function (@main)(args::Vector{String})::Cint
    out = Core.stdout                     # not Base.stdout, which is an abstract global
    a = matread(matopen(args[1]), args[2], Matrix{Float64})
    println(out, "n=", length(a), " sum=", sum(a))
    return Cint(0)
end
```

```
julia --project=. \
  $(julia -e 'print(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac.jl"))') \
  --output-exe matsum --experimental --trim=safe entry.jl < /dev/null
```

Redirecting stdin is not cosmetic: without it the juliaup launcher can panic reading a
non-blocking stdin *after* the build has already succeeded, which reads as a build failure.

The repository's `juliac/build.jl` does all of this and then checks the binary's output against
the same read performed in ordinary Julia.

## What it costs the API

`--trim=safe` forbids a call whose return type is not statically known, which is why
[`matread`](@ref) takes the type as an argument rather than inferring it from the file. It is
also why [`matsize`](@ref) returns a `Vector{Int}` and not a tuple: the rank comes from the
file, so no tuple length could be concrete.

Two internal consequences are worth knowing if you read the source. The filter pipeline is a
fixed-size tuple of filter ids rather than a vector of filter objects — a container whose
length or element type comes from the file cannot be dispatched on statically. And no helper
closes over a local that is assigned in a branch: such a local is boxed, the box reads infer
`Any`, and the enclosing function stops resolving.

## The two gates

Both run in CI, and they cover different things.

`trim/trimcheck.jl` runs the verifier over every entry point. It calls the same compiler pass a
real build does — `typeinf_ext_toplevel` under `TRIM_SAFE`, with the same `juliac-trim-base.jl`
patches — so it reports the same errors, finalizers included. A failure there is a failure of
the build. It lives outside the package test environment because TrimCheck needs the `Compiler`
stdlib from Julia 1.12, while the package itself supports 1.10.

`juliac/build.jl` builds an actual binary and runs it. That adds what the verifier cannot do:
it links, it starts up, and it roots `@main` plus every loaded package's `__init__` rather than
one signature. Both gaps have produced real failures in code that verified clean — an
artifact-backed JLL aborting in `__init__` before `main`, and a `ccall` whose library operand
is module-qualified, which verifies and then throws at run time.

```
julia --project=trim -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=trim trim/trimcheck.jl
julia --project=. juliac/build.jl
```

## Dependencies

The package depends on `Mmap` and `ChunkCodecLibZlib`. The latter `ccall`s into `Zlib_jll`,
which on Julia 1.12 is a stdlib stub declaring `libz.so.1` as a compile-time constant with no
artifact behind it. A trimmed binary therefore resolves zlib through the runpath `juliac`
already bakes in, and gains no external dependency — `libz.so.1` does not even appear in the
binary's `DT_NEEDED`.

That is the reason to be careful about adding dependencies here. An artifact-backed JLL
resolves its artifact at run time from `DEPOT_PATH`, and a trimmed binary that cannot find it
aborts before `main` rather than failing at the call site.
