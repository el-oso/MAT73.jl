# MAT73.jl

[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://el-oso.github.io/MAT73.jl/dev/)
[![CI](https://github.com/el-oso/MAT73.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/el-oso/MAT73.jl/actions/workflows/CI.yml)
[![Coverage](https://coveralls.io/repos/github/el-oso/MAT73.jl/badge.svg?branch=master)](https://coveralls.io/github/el-oso/MAT73.jl?branch=master)

Read MATLAB v7.3 (`-v7.3`) `.mat` files in pure Julia, with no HDF5 C library, and from a
binary built with `juliac --trim=safe`.

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
```

## Why the type is an argument

A variable's type is a property of the file, but `--trim=safe` rejects any call whose return
type is not known statically. So the caller states the type it expects and gets a concrete
return; the on-disk datatype class, width and signedness are all checked against it, and a
mismatch is an error rather than a reinterpretation of the bytes.

`matclass` exists so a file can be surveyed first. It returns `MAT_UNSUPPORTED` instead of
throwing, so a caller can skip what it cannot handle.

MATLAB stores dimensions reversed and elements column-major, so filling a Julia array in file
order under the reversed dimensions reproduces the MATLAB array. Nothing is transposed.

## What is read

| | |
|---|---|
| `double`, `single`, `int8`–`int64`, `uint8`–`uint64` | `Array{T,N}` |
| `logical` | `Array{Bool,N}` |
| complex numeric | `Array{Complex{T},N}` |
| `char`, `1xN` | `String` |
| `char`, any shape | `Array{Char,N}`, UTF-16 code units |
| empty arrays | shape preserved, e.g. `0x3` |
| `cell` | `Array{MatRef,N}`, one reference per element |
| `struct` | a group; fields by path, `matkeys` lists them |
| struct arrays | fields are `Array{MatRef,N}` |

A cell array's elements have no common type, and neither do a struct array's, so following
them eagerly would mean returning `Any`. They come back as references instead, read one at a
time with the type you expect:

```julia
cells = matread(f, "c", Matrix{MatRef})
matclass(f, cells[1])                     # survey before committing to a type
matread(f, cells[1], Matrix{Float64})     # follow it

matkeys(f, "s")                           # struct field names
matread(f, "s/a", Matrix{Float64})        # a field by path, nesting allowed
```

A `classdef` object holds only indices into MATLAB's own object tables in `#subsystem#`. That
indirection is resolved, so an object reads like a struct too:

```julia
matobjectclass(f, "obj")                  # "TestClasses.BasicClass"
matkeys(f, "obj")                         # property names, addprop ones included
matread(f, "obj/a", Matrix{Float64})      # a property by path
```

Storage: superblock versions 0 and 2, version-1 and version-2 object headers with
continuation blocks, old-style groups and compact groups made of link messages, and compact,
contiguous or chunked layout with the deflate and shuffle filters. MATLAB writes the first of
each pair; libhdf5, and so HDF5.jl, MAT.jl and this package's writer, write the second.

## Writing

```julia
matwrite("out.mat", "A" => A, "flags" => flags, "label" => "hello")
```

Files come out in the shape libhdf5 produces and MATLAB reads: a 512-byte user block holding
the MATLAB banner, superblock version 2, version-2 object headers, a root group of link
messages, and contiguous uncompressed datasets with the `MATLAB_*` attributes set. Numeric
arrays, `Bool` and strings are written; everything under "not read yet" is also not written.

Addresses are assigned before anything is serialised, because a dataset's header records where
its data lives. The version-2 structures carry Jenkins lookup3 checksums, which libhdf5
verifies, so a wrong one is rejected rather than tolerated.

## What is not read yet

Two limitations are silent, so they come first. Each answers a slightly different question
than the one you asked, rather than raising.

- **Struct field order.** `matkeys` lists fields in the order the group stores them, which is
  not necessarily MATLAB's. The names and values are right, the order may not be. MATLAB's
  order lives in the `MATLAB_fields` attribute, a variable-length string array that needs the
  global heap.
- **Object arrays.** An object variable may name several instances; only the first is
  followed, so `matkeys` and a property path describe that one.

The rest throw an error naming what is unsupported, or report `MAT_UNSUPPORTED`.

- **Sparse arrays.** Deliberately a limitation rather than an extension for now: there is no
  sparse code to gate. When it is written, `SparseArrays` should be a weak dependency —
  it pulls `SuiteSparse_jll`, an artifact JLL whose `__init__` aborts a trimmed binary before
  `main` when the depot is unreachable, so it must stay off the default path.
- **Built-in MATLAB objects** — `table`, `datetime`, `string` arrays and function handles.
  Their class and properties read like any object's, but turning those properties back into
  the value MATLAB shows needs per-class knowledge that is not here.
- **Characters outside the basic multilingual plane.** MATLAB stores char data as UTF-16 code
  units, and `Array{Char,N}` returns them one for one, so an astral character comes back as
  its two surrogates. The `String` method decodes properly; MAT.jl decodes char matrices to
  one `String` per row, which this package does not.
- **Properties stored inline.** A property whose value is an enumeration or a small attribute
  lives in the tables rather than in the cell array; reading one raises, since only
  cell-valued properties have somewhere to point at.
- **Compression on write.** Written datasets are contiguous and uncompressed.

`keys(f)` lists MATLAB's own entries — `#refs#` and `#subsystem#` — alongside your variables.

Storage not read: fractal-heap groups, superblock versions 1 and 3, and filters other than
deflate and shuffle. MATLAB writes none of these, but `h5repack` and other HDF5 writers do.

## Testing

Values are compared against [MAT.jl](https://github.com/JuliaIO/MAT.jl), which reads through
libhdf5 and is therefore an oracle independent of this implementation, over fixtures MATLAB
itself wrote. A test item runs TrimCheck over every entry point, since `--trim=safe` support
is a requirement rather than a nice-to-have.

TrimCheck runs the same compiler pass a real build does — `typeinf_ext_toplevel` under
`TRIM_SAFE`, with the same `juliac-trim-base.jl` patches applied — so it reports the same
verifier errors, finalizers included. What it does not do is **link or run**, and it roots
only the one signature you give it rather than `@main` plus every loaded package's `__init__`.
Both of those have produced real failures in code that verified clean: an artifact-backed JLL
whose `__init__` aborts before `main`, and a `ccall` whose library operand is module-qualified,
which verifies and then throws at run time.

So the build is a separate gate, not a stricter analyser. CI runs it, and so can you:

```
julia --project=. juliac/build.jl
```

That builds `juliac/entry.jl` with `--trim=safe` and fails unless the resulting binary prints
the same thing as the ordinary Julia path.
