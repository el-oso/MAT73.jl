# The format

**A version 7.3 `.mat` file is an HDF5 file with a MATLAB label in front and MATLAB notes
beside each array.**

HDF5 is a general file format for arrays. It says how the bytes are stored. It does not say
what MATLAB means by them. The notes beside each array carry that meaning. Their names all
start with `MATLAB_`.

## What this package reads

| MATLAB type | Julia type |
|---|---|
| `double`, `single` | `Array{Float64,N}`, `Array{Float32,N}` |
| `int8` to `int64`, `uint8` to `uint64` | `Array{T,N}` |
| `logical` | `Array{Bool,N}` |
| complex numbers | `Array{Complex{T},N}` |
| `char`, one row | `String` |
| `char`, any shape | `Array{Char,N}`, as 16-bit units |
| empty arrays | the shape stays, so a `0x3` stays `0x3` |
| `cell` | `Array{MatRef,N}`, one mark for each item |
| `struct` | fields by path; `matkeys` gives the names |
| struct arrays | each field is an `Array{MatRef,N}` |
| objects of a class you wrote | properties by path |

## Boxes with mixed contents

**A cell array gives you marks, not values. You follow one mark at a time.**

Think of a cloakroom. You get a numbered ticket, not the coat. You hand back one ticket and
get one coat.

The items in a cell array can have different types. The same is true for each field of a
struct array. A function that returned all of them at once would have no single type. So you
get one mark for each item. The mark type is [`MatRef`](@ref).

```julia
cells = matread(f, "c", Matrix{MatRef})
matclass(f, cells[1])                      # look before you choose a type
matread(f, cells[1], Matrix{Float64})      # follow the mark

matkeys(f, "s")                            # the field names of a struct
matread(f, "s/a", Matrix{Float64})         # one field, by path
```

A cell inside a cell gives you more marks. The steps stay the same. Paths can also go deeper,
such as `"s/inner/a"`.

## Objects of a class

**An object holds no data. It holds numbers that point into a table.**

Think of a library catalogue card. The card is not the book. The card tells you the shelf.

MATLAB keeps that table in a hidden entry named `#subsystem#`. MathWorks does not publish the
layout of the table. People worked it out by reading files. The notes they wrote are
[here](https://github.com/foreverallama/matio/blob/main/docs/subsystem_data_format.md).

This package follows the numbers for you. An object then behaves like a struct.

```julia
matobjectclass(f, "obj")             # "TestClasses.BasicClass", with the namespace
matkeys(f, "obj")                    # the property names
matread(f, "obj/a", Matrix{Float64}) # one property, by path
```

Properties added later with `addprop` are in the list too. Each one is itself a small object.
It holds the name you gave and the value. This package follows that step as well.

`matclass` still reports `MAT_UNSUPPORTED` for an object. That function answers one question:
is this a plain array? An object is not. Ask `matobjectclass` instead.

## Empty arrays

**An empty array keeps its shape.**

MATLAB does not store zero items. It stores a short list of the dimensions, with a note named
`MATLAB_empty`. So a `0x3` array stays a `0x3` array.

## Two notes do the work

HDF5 cannot tell a true-or-false value from a small whole number. They have the same bytes.
Two MATLAB notes settle it:

- `MATLAB_class` gives the MATLAB type name, such as `double`.
- `MATLAB_int_decode` marks `logical` with a 1 and `char` with a 2.

If you read a `logical` array as `UInt8`, the package stops with an error. The reverse also
stops. Neither case is a silent success.

## How the bytes are stored

**Two programs write this format in 2 different shapes. This package reads both.**

| | MATLAB writes | The HDF5 C library writes |
|---|---|---|
| Superblock | version 0 | version 2 |
| Object headers | version 1 | version 2 |
| Groups | local heap and a version 1 tree | link messages |

MATLAB writes the left column. The HDF5 C library writes the right column. HDF5.jl, MAT.jl and
this package all write the right column. MATLAB reads both.

The bytes of an array sit in one of 3 layouts:

1. **compact**, inside the header, for very small arrays
2. **contiguous**, in one block
3. **chunked**, in blocks, and often compressed

**Most real arrays use the chunked layout.** MATLAB compresses anything above a few hundred
bytes. Only the smallest variables are compact. This package reads chunked data with the
deflate and shuffle filters.

## What this package writes

`matwrite` writes the same shape as the HDF5 C library:

1. a 512-byte block in front, holding the MATLAB label
2. superblock version 2
3. version 2 object headers
4. a root group made of link messages
5. arrays in one block each, with no compression
6. the `MATLAB_` notes beside each array

Version 2 parts each carry a running total of their own bytes. The HDF5 C library checks these
totals. A wrong total is rejected. It is not accepted quietly.

This package writes numbers, `Bool` values and text. It does not compress. Files are therefore
larger than the files MATLAB writes.

## What this package does not do

Two limits are quiet. The package gives an answer, but not the answer you asked for. These
come first, because a quiet limit is easy to miss.

- **The order of struct fields.** `matkeys` gives the names in file order. MATLAB may use a
  different order. The names are correct. The values are correct. Only the order can differ.
  MATLAB keeps its order in a note named `MATLAB_fields`. That note uses a storage area this
  package does not read yet.
- **Arrays of objects.** One variable can point to many objects. This package uses the first
  one. `matobjectclass`, `matkeys` and a property path all describe that first object.

The other limits stop with an error, or report `MAT_UNSUPPORTED`.

- **Sparse arrays.** When this is added, `SparseArrays` must be an optional dependency. It
  pulls in a library that looks up files on disk when it starts. A small compiled program then
  stops before it runs, if it cannot find those files. So it must stay off the normal path.
- **Objects of the MATLAB types** `table`, `datetime`, `string` and function handles. These
  are objects like any other. Their class and their properties read correctly. Building the
  value that MATLAB shows needs a rule for each of those types. Classes you write yourself
  need no such rule.
- **Properties kept in the table.** Most properties point to a value elsewhere. Some small
  ones sit in the table itself. Only the first kind has an address to follow, so the second
  kind stops with an error.
- **Text above code point 65535.** MATLAB keeps text as 16-bit units. `Array{Char,N}` gives
  you those units, one for one. One rare character then arrives as 2 units. The `String`
  method joins them correctly. MAT.jl gives one `String` for each row instead. This package
  gives what MATLAB stores.
- **Compression when writing.** Arrays are written in one block each.

`keys(f)` also lists 2 names that MATLAB uses for itself: `#refs#` and `#subsystem#`. They
hold the contents of cells and the object tables. Skip them if you only want your own
variables.

The package does not read some file layouts: fractal heap groups, superblock versions 1 and 3,
and filters other than deflate and shuffle. MATLAB does not write these. Other tools can.

Two limits are set by fixed sizes in the code: 8 dimensions for an array, and 4 filters for
one array. MATLAB stays far below both.

## Tests

**Every value is compared against a second, independent reader.**

The tests use MAT.jl. That package reads through the HDF5 C library. It shares no code with
this one. The test files come from MATLAB itself.

Files that this package writes are read back through the same C library. That library checks
the running totals and the structure. A bad file fails there. A file cannot pass by being
wrong in the same way twice.
