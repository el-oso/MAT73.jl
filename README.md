# MAT73.jl

[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://el-oso.github.io/MAT73.jl/dev/)
[![CI](https://github.com/el-oso/MAT73.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/el-oso/MAT73.jl/actions/workflows/CI.yml)
[![Coverage](https://coveralls.io/repos/github/el-oso/MAT73.jl/badge.svg?branch=master)](https://coveralls.io/github/el-oso/MAT73.jl?branch=master)

**This package reads and writes MATLAB `.mat` files of version 7.3. It uses only Julia code.
It does not use the HDF5 C library.**

MATLAB writes version 7.3 files when you use `save -v7.3`.

## Example

```julia
using MAT73

d = matread("results.mat")             # every variable, in a Dict
d["A"]

matwrite("out.mat", "A" => d["A"], "label" => "hello")
```

One variable at a time:

```julia
f = matopen("results.mat")
keys(f)                                # the names of the variables
matsize(f, "A")                        # [128, 128]
A = matread(f, "A")                    # a Matrix{Float64}
```

## Two ways to read

**Use the short way. Give the type only if you build a small compiled program.**

| | short way | with the type |
|---|---|---|
| whole file | `matread(path)` | — |
| one variable | `matread(f, "A")` | `matread(f, "A", Matrix{Float64})` |
| works in a small program | no | yes |

The short way works out the type from the file, as MAT.jl does. It is the one to use in
ordinary Julia code.

The long way is for a tool named `juliac`. That tool builds a small program from Julia code.
Its option `--trim=safe` rejects any function that can return more than one type. So the
caller states the type instead.

A program that never calls the short way does not carry it. The build removes it.

## Reading several variables at once

**`@matload` gives you the short way and the fixed return type at the same time.**

You list the variables once. The macro writes one normal typed read for each line, with the
type written out. So it works inside a small compiled program.

```julia
v = @matload f begin
    A::Matrix{Float64}          # an array
    n::Int64                    # a single number
    label::String               # one row of text
    gain = "cfg/gain"::Float64  # a field of a struct, under the name you choose
end

v.A
v.n
v.gain
```

You get a named tuple. Its type is known before the program runs.

A plain number type means a MATLAB scalar, which is a 1x1 array in the file. You get the
value. If the variable holds more than one value, this stops with an error.

The two line forms:

| you write | it reads |
|---|---|
| `name::Type` | the variable called `name` |
| `name = "a/path"::Type` | that path, under the name `name` |

## What the check does

When you give the type, the package does 3 checks against the file:

1. the kind of number, such as a whole number or a decimal number
2. the width in bytes
3. the sign, for whole numbers

If a check fails, the package stops with an error. It does not read the bytes as the wrong
type.

Use `matclass` first if you do not know what is in the file. It gives a name for the type. It
gives `MAT_UNSUPPORTED` for a type this package does not read. It does not stop with an error.

## Order of the dimensions

**You get the same array that MATLAB shows. Nothing is turned around.**

MATLAB and Julia both put the first dimension down the columns. The file keeps the dimensions
in the opposite order. The two effects cancel.

## What this package reads

| MATLAB type | Julia type |
|---|---|
| `double`, `single` | `Array{Float64,N}`, `Array{Float32,N}` |
| `int8` to `int64`, `uint8` to `uint64` | `Array{T,N}` |
| `logical` | `Array{Bool,N}` |
| complex numbers | `Array{Complex{T},N}` |
| `char`, one row | `String` |
| `char`, any shape | `Array{Char,N}` |
| empty arrays | the shape stays, such as `0x3` |
| `cell` | `Array{MatRef,N}`, one mark for each item |
| `struct` | fields by path; `matkeys` gives the names |
| struct arrays | each field is an `Array{MatRef,N}` |
| objects of a class you wrote | properties by path |
| `datetime` | `Array{DateTime,N}` |
| `string` | `Array{String,N}` |

## Boxes with mixed contents

**A cell array gives you marks, not values. You follow one mark at a time.**

Think of a cloakroom. You get a numbered ticket, not the coat. You hand back one ticket and
get one coat.

The items in a cell array can have different types. A function that returns all of them at
once would have no single type. So you get one mark for each item. The mark type is `MatRef`.

```julia
cells = matread(f, "c", Matrix{MatRef})
matclass(f, cells[1])                     # look before you choose a type
matread(f, cells[1], Matrix{Float64})     # follow the mark

matkeys(f, "s")                           # the field names of a struct
matread(f, "s/a", Matrix{Float64})        # one field, by path
```

A cell inside a cell gives you more marks. The steps stay the same.

## Objects of a class

**An object holds no data. It holds numbers that point into a table.**

Think of a library catalogue card. The card is not the book. The card tells you the shelf.

MATLAB keeps the table in a hidden part of the file. This package follows the numbers for you.
An object then behaves like a struct.

```julia
matobjectclass(f, "obj")                  # "TestClasses.BasicClass"
matkeys(f, "obj")                         # the property names
matread(f, "obj/a", Matrix{Float64})      # one property, by path
```

Properties added later with `addprop` are in the list too. An object held by another object
is found as well.

A `datetime` and a `string` are objects too, and the package knows the rule for each. They
read as `Array{DateTime,N}` and `Array{String,N}`.

## Writing

```julia
matwrite("out.mat", "A" => A, "flags" => flags, "label" => "hello")
```

The package writes files in the shape that MATLAB reads. It writes numbers, `Bool` values and
text. It does not compress. Files are therefore larger than the files MATLAB writes.

## What this package does not do

Two limits are quiet. The package gives an answer, but not the answer you asked for. These
come first, because a quiet limit is easy to miss.

- **The order of struct fields.** `matkeys` gives the names in file order. MATLAB may use a
  different order. The names are correct. The values are correct. Only the order can differ.
- **Arrays of objects.** One variable can point to many objects. This package uses the first
  one. `matobjectclass`, `matkeys` and a property path all describe that first object.

The other limits stop with an error, or report `MAT_UNSUPPORTED`.

- **Sparse arrays.**
- **Objects of the MATLAB types** `table`, `categorical`, `duration` and function handles.
  The package reads their class and their properties. It cannot build the value that MATLAB
  shows. That step needs a rule for each type, and only `datetime` and `string` have one so
  far.
- **The default value of a property.** A class can give a property a value in its own
  definition. The package does not read those, so an object that never set the property
  lists no property at all.
- **Properties kept in the table.** Most properties point to a value. Some small ones sit in
  the table itself. The package cannot read those.
- **Text above code point 65535.** MATLAB keeps text as 16-bit units. `Array{Char,N}` gives
  you those units. One rare character then arrives as 2 units. The `String` method joins them
  correctly.
- **Compression when writing.**

`keys(f)` also lists 2 names that MATLAB uses for itself: `#refs#` and `#subsystem#`. Skip
them if you only want your own variables.

The package does not read some file layouts: fractal heap groups, superblock versions 1 and 3,
and filters other than deflate and shuffle. MATLAB does not write these. Other tools can.

## Tests

**Every value is compared against a second, independent reader.**

The tests use MAT.jl. That package reads through the HDF5 C library. It shares no code with
this one. The test files come from MATLAB itself.

Files that this package writes are read back through the same C library. That library checks
the internal totals in the file. A bad file fails there. A file cannot pass by being wrong in
the same way twice.

## The small-program check

**A test proves that this package works inside a small compiled program.**

Two checks run, and they cover different things.

1. `trim/trimcheck.jl` runs the compiler check on every entry point. It finds the same
   problems the real build finds.
2. `juliac/build.jl` builds a real program and runs it. This step also links the program and
   starts it. The first check does neither.

Run them yourself:

```
julia --project=. juliac/build.jl
```

The build fails unless the program prints the same answer as normal Julia code.
