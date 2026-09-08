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
| `char`, any shape | `Array{Char,N}`, UTF-16 code units |
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

## MATLAB objects

A `classdef` instance holds no data of its own. The variable is a `uint32` array of indices,
and the values live in `#subsystem#` behind MATLAB's own object tables — a format MathWorks
does not document, [reverse-engineered by the
community](https://github.com/foreverallama/matio/blob/main/docs/subsystem_data_format.md).

The indirection is resolved here, so an object behaves like a struct:

```julia
matobjectclass(f, "obj")             # "TestClasses.BasicClass", namespace included
matkeys(f, "obj")                    # property names
matread(f, "obj/a", Matrix{Float64}) # a property by path
```

`matclass` still reports `MAT_UNSUPPORTED` for an object, because it answers the
plain-array question and an object is not a plain array; `matobjectclass` is the one to ask.

Only properties whose value is stored in the subsystem's cell array can be read. A property
held inline — an enumeration or a small attribute — raises rather than being guessed at.

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

Three limitations are silent, so they come first. Each gives a right answer to a slightly
different question than the one you asked.

- **Struct field order.** `matkeys` lists fields in the order the group stores them, which is
  not necessarily MATLAB's. The names and values are right, the order may not be. MATLAB's
  order lives in the `MATLAB_fields` attribute, a variable-length string array that needs the
  global heap.
- **Object arrays** name several instances; only the first is described. See below.
- **Dynamic properties** are absent from `matkeys` rather than reported. See below.

The rest raise an error naming what is unsupported, or report `MAT_UNSUPPORTED`.

- **Sparse arrays.** When implemented, `SparseArrays` will be a weak dependency: it pulls
  `SuiteSparse_jll`, an artifact JLL whose `__init__` aborts a trimmed binary before `main`
  when the depot is unreachable, so it must stay off the default path.
- **Built-in MATLAB objects** — `table`, `datetime`, `string` arrays and function handles.
  These are MCOS objects like any `classdef` instance, and their class and properties read
  fine, but reconstructing the value MATLAB would show means knowing what each built-in class
  does with its properties. `classdef` instances of your own classes have no such layer.
- **Object arrays.** An object variable may name several instances; only the first is
  followed, so `matkeys` and a property path describe that one.
- **Dynamic properties**, those added with `addprop`. They are held in a region of the
  subsystem tables this parser reads past, so they are missing from `matkeys` rather than
  reported.
- **Properties stored inline.** A property whose value is an enumeration or a small attribute
  is held in the tables rather than in the cell array, and reading one raises. Only
  cell-valued properties have somewhere to point at.
- **Characters outside the basic multilingual plane.** MATLAB stores char data as UTF-16 code
  units, and `Array{Char,N}` returns them one for one, so an astral character comes back as
  its two surrogates. The `String` method decodes properly. MAT.jl instead decodes a char
  matrix to one `String` per row; this package returns what MATLAB stores.

- **Compression on write.** Written datasets are contiguous and uncompressed, so files are
  larger than MATLAB's own.

Storage not read: fractal-heap groups, superblock versions 1 and 3, and filters other than
deflate and shuffle. MATLAB writes none of these, though `h5repack` and other HDF5 writers do.

`keys(f)` lists MATLAB's own entries — `#refs#` and `#subsystem#` — alongside your variables.
They are where cell contents and object tables live, and skipping them is left to the caller.

Rank is capped at 8 dimensions and a filter pipeline at 4 entries, both far above anything
MATLAB produces.

## Testing

Values are compared against MAT.jl, which reads through libhdf5 and is therefore an oracle
independent of this implementation, over fixtures MATLAB itself wrote. Written files are read
back through libhdf5 for the same reason — it verifies the checksums and the structure, so a
malformed file fails there rather than passing a self-consistent round-trip.
