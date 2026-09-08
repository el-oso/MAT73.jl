# The format

A `.mat` file written by `save -v7.3` is an HDF5 file with a MATLAB banner in front of it and
a handful of `MATLAB_*` attributes beside each dataset. HDF5 says how the bytes are stored;
those attributes say what they mean.

## What is read

| MATLAB class | Julia type |
|---|---|
| `double`, `single` | `Array{Float64,N}`, `Array{Float32,N}` |
| `int8`–`int64`, `uint8`–`uint64` | `Array{T,N}` |
| `logical` | `Array{Bool,N}` |
| complex numeric | `Array{Complex{T},N}` |
| `char`, `1xN` | `String` |
| empty arrays | shape preserved, so a `0x3` stays `0x3` |
| `cell` | `Array{MatRef,N}`, one reference per element |
| `struct` | a group; fields by path, `matkeys` lists them |
| struct arrays | fields are `Array{MatRef,N}`, one reference per element |

## Containers

A cell array's elements have no common type, and neither do a struct array's, so following
them eagerly would mean returning `Any`. Instead they come back as [`MatRef`](@ref) values,
and you read each one with the type you expect — the same discipline as everywhere else:

```julia
cells = matread(f, "c", Matrix{MatRef})
matclass(f, cells[1])                      # survey before committing to a type
matread(f, cells[1], Matrix{Float64})      # follow it

matkeys(f, "s")                            # field names of a struct
matread(f, "s/a", Matrix{Float64})         # a field by path, nested paths allowed
```

Nesting works the same way: a cell inside a cell yields another `Array{MatRef}`.

An empty array is not stored as zero elements. MATLAB writes a `uint64` vector holding the
dimensions, tagged with `MATLAB_empty`, which is how the shape survives.

Two attributes do the work that HDF5 cannot: `MATLAB_class` names the class, and
`MATLAB_int_decode` distinguishes `logical` (1) and `char` (2) from the plain integers they are
otherwise indistinguishable from. Reading a logical array as `UInt8` is an error rather than a
silent success, and vice versa.

## Storage

Both shapes of the format are read:

| | MATLAB writes | libhdf5 writes |
|---|---|---|
| Superblock | version 0 | version 2 |
| Object headers | version 1 | version 2 |
| Groups | local heap + version-1 B-tree | link messages |

MATLAB produces the first column. libhdf5 produces the second, and so do HDF5.jl, MAT.jl and
this package's own writer — MATLAB reads both.

Data layout: compact, contiguous and chunked, the last with the deflate and shuffle filters.
This matters more than it looks. MATLAB compresses anything beyond a few hundred bytes, so
chunked storage is the path essentially every real array takes; only the smallest variables
are stored compact.

## What is written

`matwrite` emits the libhdf5 shape: a 512-byte user block holding the MATLAB banner,
superblock version 2, version-2 object headers, a root group of link messages, and contiguous
uncompressed datasets carrying the `MATLAB_*` attributes.

The version-2 structures each carry a Jenkins lookup3 checksum. libhdf5 verifies them, so a
wrong checksum is rejected outright rather than tolerated.

Numeric arrays, `Bool` and strings are written. Compression on write is not implemented, so
files are larger than MATLAB's own.

## What is not handled

Each of these raises an error naming what is unsupported, or reports `MAT_UNSUPPORTED`.

- **Struct field order.** Fields are listed in the order the group stores them, not MATLAB's.
  MATLAB's order lives in the `MATLAB_fields` attribute, which is a variable-length string
  array and so needs the global heap.
- **Sparse arrays.** When implemented, `SparseArrays` will be a weak dependency: it pulls
  `SuiteSparse_jll`, an artifact JLL whose `__init__` aborts a trimmed binary before `main`
  when the depot is unreachable, so it must stay off the default path.
- **MATLAB objects** — `classdef` instances, `table`, `datetime`, `string` arrays and function
  handles. These live in `#subsystem#` in MATLAB's own MCOS encoding.
- **Char matrices.** Only a `1xN` char array has a single string form; a char matrix is several
  rows and is refused rather than flattened.

Storage not read: fractal-heap groups, superblock versions 1 and 3, and filters other than
deflate and shuffle. MATLAB writes none of these, though `h5repack` and other HDF5 writers do.

Rank is capped at 8 dimensions and a filter pipeline at 4 entries, both far above anything
MATLAB produces.

## Testing

Values are compared against MAT.jl, which reads through libhdf5 and is therefore an oracle
independent of this implementation, over fixtures MATLAB itself wrote. Written files are read
back through libhdf5 for the same reason — it verifies the checksums and the structure, so a
malformed file fails there rather than passing a self-consistent round-trip.
