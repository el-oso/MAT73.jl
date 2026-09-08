# MAT73.jl

**This package reads and writes MATLAB `.mat` files of version 7.3. It uses only Julia code.
It does not use the HDF5 C library. It also works inside a small compiled program.**

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

## What this package covers

**It reads one file format only: the format built on HDF5.**

MATLAB has older formats, from version 4 to version 7. They use a different container. MAT.jl
already covers them in the Julia ecosystem. This package does not repeat that work.

Inside version 7.3 it reads numbers, true and false values, text, complex numbers and empty
arrays. It reads cell arrays, structs and objects. [The format](format.md) has the full list,
and the list of what it cannot do.

## Two ways to read

**Use the short way. Give the type only if you build a small compiled program.**

| | short way | with the type |
|---|---|---|
| whole file | `matread(path)` | — |
| one variable | `matread(f, "A")` | `matread(f, "A", Matrix{Float64})` |
| works in a small program | no | yes |

The short way works out the type from the file, as MAT.jl does. Use it in ordinary Julia code.

The long way exists for a tool named `juliac`. That tool builds a small program from Julia
code. Its option `--trim=safe` rejects any function that can return more than one type. A file
can hold many types. So the caller states the type instead.

Think of a parcel with no label. You must say what is inside before you open it.

A program that never calls the short way does not carry it. The build removes it. So the short
way costs nothing to a program that does not use it.

## What the check does

When you give the type, the package does 3 checks against the file:

- the kind of number, such as a whole number or a decimal number
- the width in bytes
- the sign, for whole numbers

If a check fails, the package stops with an error. It does not read the bytes as the wrong
type. This matters. A check on the width alone can read past the end of a smaller array. You
then get numbers that look real but are not.

Use [`matclass`](@ref) first if you do not know what is in the file. It gives
`MAT_UNSUPPORTED` for a type this package does not read. It does not stop with an error, so
you can look through a whole file safely.

## Reading several variables at once

**`@matload` gives you the short way and the fixed return type at the same time.**

### Why it exists

Look at the 2 ways again. Each one costs you something.

- `matread(f, "A")` is short. Its result type is not fixed, so a small compiled program
  cannot use it.
- `matread(f, "A", Matrix{Float64})` has a fixed type. You repeat the call for each variable,
  and the file name and the type sit far apart.

`@matload` removes the repetition and keeps the fixed type. You list the variables once. The
macro writes one normal typed read for each line. The types stay in the code it writes, so
nothing is worked out while the program runs.

Think of a shopping list. You write the list once at home. In the shop you collect the items
one by one. The list did not buy anything; it only saved you from remembering.

### Example 1: a few arrays

```julia
v = @matload f begin
    A::Matrix{Float64}
    B::Array{Float64,3}
    flags::Matrix{Bool}
end

v.A
v.flags
```

You get a named tuple. Its type is known before the program runs.

### Example 2: single numbers

A MATLAB scalar is a 1x1 array in the file. Ask for a plain number type and you get the
value, not the array.

```julia
v = @matload f begin
    n::Int64            # the value, such as 42
    gain::Float64
    count::Matrix{Int64}  # the 1x1 array, if you want it
end
```

If the variable holds more than one value, this stops with an error. It does not pick one.

### Example 3: fields of a struct

Use a path. Give the field the name you want in the result.

```julia
v = @matload f begin
    gain = "cfg/gain"::Float64
    mode = "cfg/mode"::String
end

v.gain
v.mode
```

### Example 4: properties of an object

An object works the same way as a struct.

```julia
v = @matload f begin
    label = "obj/Name"::String
    data  = "obj/DynamicData"::Float64
end
```

### Example 5: one variable, no block

```julia
v = @matload f A::Matrix{Float64}
v.A
```

### The two line forms

| you write | it reads |
|---|---|
| `name::Type` | the variable called `name` |
| `name = "a/path"::Type` | that path, under the name `name` |

## Order of the dimensions

**You get the same array that MATLAB shows. Nothing is turned around. Nothing is copied to
reorder it.**

Two facts cancel each other:

- MATLAB and Julia both put the first dimension down the columns.
- The file keeps the list of dimensions in the opposite order.

So the package fills a Julia array in file order, under the reversed dimensions. The result
matches MATLAB.

## Which package to use

**Use MAT.jl. Use this package only if you need one of 2 things.**

Pick MAT73.jl when you need:

- no C library among your dependencies, or
- to read a `.mat` file inside a small compiled program.

For everything else, MAT.jl is the better tool.

| | MAT.jl | MAT73.jl |
|---|---|---|
| MATLAB versions | 4, 5, 6, 7 and 7.3 | 7.3 only |
| The HDF5 C library | needed | not used |
| `matread(path)` gives a `Dict` | yes | yes |
| `table`, `datetime`, `string` | full values | class and properties only |
| sparse arrays | yes | no |
| works in a small compiled program | no | yes |

The two agree where they overlap. The tests here read files that MATLAB wrote, and compare
every value against MAT.jl.
