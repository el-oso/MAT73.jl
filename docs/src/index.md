# MAT73.jl

Read and write HDF5-based MATLAB `.mat` files — the format `save -v7.3` produces — in pure
Julia, with no HDF5 C library, and from a binary built with `juliac --trim=safe`.

```julia
using MAT73

f = matopen("results.mat")
keys(f)                                # top-level variable names
matclass(f, "A")                       # MAT_DOUBLE
matsize(f, "A")                        # [128, 128]

A     = matread(f, "A", Matrix{Float64})
flags = matread(f, "flags", Matrix{Bool})
z     = matread(f, "z", Matrix{ComplexF64})
label = matread(f, "label", String)

matwrite("out.mat", "A" => A, "flags" => flags, "label" => label)
```

## Scope

This package handles the HDF5-based format only. MATLAB's earlier formats — v4 through v7 —
are a different container entirely; [MAT.jl](https://github.com/JuliaIO/MAT.jl) already covers
them in the Julia ecosystem, and this package does not duplicate that.

Within v7.3 it covers numeric arrays, logical, char, complex and empty arrays, over every
storage layout MATLAB emits. [The format](format.md) lists exactly what is and is not handled.

## Why the type is an argument

A variable's type is a property of the file, so the obvious signature would return `Any`. That
is exactly what `--trim=safe` rejects: it refuses any call whose return type is not known
statically. The caller therefore states the type it expects:

```julia
A = matread(f, "A", Matrix{Float64})
```

The on-disk datatype class, width and signedness are all checked against `T`, and a mismatch
raises rather than reinterpreting the bytes. That matters more than it sounds: a size-only
check reads past the end of a smaller dataset and returns plausible garbage.

Use [`matclass`](@ref) to survey a file first. It returns `MAT_UNSUPPORTED` instead of throwing,
so a caller can skip what it cannot handle without exception handling.

## Dimension order

MATLAB stores dimensions reversed relative to HDF5, and its elements column-major — which is
also Julia's order. Filling a Julia array in file order under the reversed dimensions therefore
reproduces the MATLAB array exactly. Nothing is transposed, and no copy is made to reorder.

## Comparison with MAT.jl

[MAT.jl](https://github.com/JuliaIO/MAT.jl) is the general-purpose choice: it reads every MAT
version, including cell arrays, structs, sparse matrices and MATLAB objects. It reaches v7.3
through HDF5.jl and therefore through libhdf5.

Reach for MAT73.jl when you need one of the two things it does differently: no C library in the
dependency tree, or a `.mat` read from inside a trimmed binary. Its test suite compares against
MAT.jl on MATLAB-written files, so the two agree where they overlap.
