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
| `datetime` | `Array{DateTime,N}` |
| `string`, `categorical` | `Array{String,N}` |
| `table` | a `NamedTuple` of columns |
| function handles | the values MATLAB stored, by path |
| objects of a class written before 2008 | properties by path |

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

An object held by another object is found too. MATLAB writes the note that marks an object
only at the top level. Inside the hidden entry it writes none, so the only mark left is the
tag the index array starts with. This package reads that tag, as MATLAB does.

### Dates

A MATLAB `datetime` is an object too, but this package knows the rule for it. Its `data`
property counts milliseconds from 1 January 1970, so it reads as a `DateTime`:

```julia
using Dates
t = matread(f, "when", Matrix{DateTime})   # or matread(f, "when")
```

A time zone on the MATLAB side is not applied. MATLAB may store a step smaller than a
millisecond, which a `DateTime` cannot hold, and that part is dropped.

### Text held as a `string`

A MATLAB `string` is an object as well, and this package knows its rule too.

A `string` is not a `char`. MATLAB keeps a `char` array as text beside the array. It keeps a
`string` array as one block of numbers, holding in order: a version, the number of
dimensions, the dimensions, the length of each piece of text, and then all the text back to
back as 16-bit units.

```julia
names = matread(f, "names", Matrix{String})   # or matread(f, "names")
```

You get one `String` for each element, in the shape MATLAB used.

A `categorical` reads as text too. MATLAB keeps a list of the choices and one number for each
element, counting into that list. You get the text of the choice.

### Tables

**A table reads as a named tuple of columns.**

Think of a filing cabinet. Each drawer has a label on the front and holds one kind of paper.
You take out a whole drawer, not one sheet.

A named tuple of vectors is already a column table, so anything that reads the Tables.jl
interface takes the result as it is. This package needs no dependency for that.

```julia
t = matread(f, "flights")     # every column, with the types taken from the file
t.Customer

using DataFrames
DataFrame(t)
```

For a small compiled program you state the columns and their types. Each type is the type of
a whole column, so it is a `Vector`:

```julia
t = matread(f, "flights", NamedTuple{
    (:FlightNum, :Customer),
    Tuple{Vector{Float64}, Vector{String}},
})
```

You may ask for some of the columns only, in any order. A name the table does not have stops
with an error.

### Function handles

**A saved function handle holds no code. It holds the name, or the text you typed.**

Think of a phone number written on a card. The card does not ring. Someone has to dial it.

MATLAB stores a named handle such as `@sin` as the name `sin`. It stores an anonymous handle
such as `@(x) x` as the text of the expression, together with the values it captured when you
made it. It also stores the folder MATLAB was installed in.

So you can read what a saved file referred to. You cannot call it from Julia; there is nothing
to call.

A handle reads as a set of named values, like a struct:

```julia
matkeys(f, "h")                            # ["function_handle", "matlabroot", ...]
matread(f, "h/function_handle/function", String)
```

`matobjectclass` gives an empty string for a handle. A handle carries the note that marks an
object, but it is not a `classdef` instance, so it has no class name in the hidden table.

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

- **compact**, inside the header, for very small arrays
- **contiguous**, in one block
- **chunked**, in blocks, and often compressed

**Most real arrays use the chunked layout.** MATLAB compresses anything above a few hundred
bytes. Only the smallest variables are compact. This package reads chunked data with the
deflate and shuffle filters.

## What this package writes

`matwrite` writes the same shape as the HDF5 C library:

- a 512-byte block in front, holding the MATLAB label
- superblock version 2
- version 2 object headers
- a root group made of link messages
- arrays in one block each, with no compression
- the `MATLAB_` notes beside each array

Version 2 parts each carry a running total of their own bytes. The HDF5 C library checks these
totals. A wrong total is rejected. It is not accepted quietly.

### What you can write

| you give | MATLAB sees |
|---|---|
| an `Array` of numbers or `Bool` | an array of the matching type |
| one number or `Bool` | a 1x1 array |
| a `String` | text |
| a `NamedTuple` | a struct, one field per name |
| a `Tuple` | a cell array of one row |

**A named tuple becomes a struct. A tuple becomes a cell array. Both nest.**

```julia
matwrite(
    "run.mat",
    "cfg"  => (gain = 2.5, mode = "fast", limits = (1.0, 10.0)),
    "runs" => ([1.0 2.0], "second", (name = "third", ok = true)),
)
```

Every type is settled while your program is compiled, so writing works inside a small compiled
program, as reading does.

A struct is a group holding one member for each field, so a struct inside a struct is a group
inside a group.

A cell holds no values. It holds the address of each item, as a library catalogue card holds a
shelf number. The items themselves are written in a hidden entry named `#refs#`, which is where
MATLAB puts them too. An item must be linked under some name, or nothing could walk to it.

This package does not compress. Files are therefore larger than the files MATLAB writes.

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
- **Objects of the MATLAB types** `duration` and `calendarDuration`. These are objects like
  any other. Their class and their properties read correctly. Building the value that MATLAB
  shows needs a rule for each type, and only `datetime`, `string`, `categorical` and `table`
  have one so far. Classes you write yourself need no such rule.
- **Calling a function handle.** The file holds a name, or the text of an expression. Turning
  either one into something you can call is a job for a different tool.
- **An element of a `categorical` with no choice.** MATLAB shows it as `<undefined>`. There
  is no text for it, so this stops with an error rather than giving back an empty one.
- **The row names of a table.** Only the columns are read.
- **The default value of a property.** A class can give a property a value in its own
  definition. MATLAB keeps those values in a part of the table this package does not read
  yet, so an object that never set the property lists no property at all.
- **Properties kept in the table.** Most properties point to a value elsewhere. Some small
  ones sit in the table itself. Only the first kind has an address to follow, so the second
  kind stops with an error.
- **Text above code point 65535.** MATLAB keeps text as 16-bit units. `Array{Char,N}` gives
  you those units, one for one. One rare character then arrives as 2 units. The `String`
  method joins them correctly. MAT.jl gives one `String` for each row instead. This package
  gives what MATLAB stores.
- **Compression when writing.** Arrays are written in one block each.
- **Writing a cell array with no items.** A cell of one row needs at least one item, so an
  empty tuple stops with an error rather than writing a shape MATLAB may not accept.
- **Writing complex numbers, sparse arrays, `datetime`, `string` or objects.** These read, but
  nothing writes them yet.

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
