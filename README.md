# PureMAT.jl

Read MATLAB v7.3 (`-v7.3`) `.mat` files in pure Julia, with no HDF5 C library, and from a
binary built with `juliac --trim=safe`.

```julia
using PureMAT

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
| empty arrays | shape preserved, e.g. `0x3` |

Storage: superblock version 0, version-1 object headers with continuation blocks, old-style
groups, and compact, contiguous or chunked layout with the deflate and shuffle filters.

## What is not read yet

Each of these throws an error naming what is unsupported, or reports `MAT_UNSUPPORTED`.

- **Sparse arrays.** Deliberately a limitation rather than an extension for now: there is no
  sparse code to gate. When it is written, `SparseArrays` should be a weak dependency —
  it pulls `SuiteSparse_jll`, an artifact JLL whose `__init__` aborts a trimmed binary before
  `main` when the depot is unreachable, so it must stay off the default path.
- **Cell arrays** and **structs**, including struct arrays. Both need traversal of non-root
  groups and dereferencing of HDF5 object references into `#refs#`; structs additionally need
  variable-length string attributes, which live in the global heap.
- **MATLAB objects** — `classdef` instances, `table`, `datetime`, `string` arrays and function
  handles. These live in `#subsystem#` in MATLAB's own MCOS encoding.
- **Char matrices.** Only a `1xN` char array has a single string form; a char matrix is
  several rows and is refused rather than flattened.
- **Writing.** Nothing is written yet.

Storage not read: fractal-heap groups, version-2 object headers, superblock versions other
than 0, and filters other than deflate and shuffle. MATLAB itself writes none of these, but
`h5repack` and other HDF5 writers do.

## Testing

Values are compared against [MAT.jl](https://github.com/JuliaIO/MAT.jl), which reads through
libhdf5 and is therefore an oracle independent of this implementation, over fixtures MATLAB
itself wrote. A test item runs TrimCheck over every entry point, since `--trim=safe` support
is a requirement rather than a nice-to-have.

TrimCheck is a dev-time heuristic and not the last word: it does not model finalizers, and it
analyses stock Base while `juliac` raises `max_args`. A real `juliac` build is the
authoritative gate.
