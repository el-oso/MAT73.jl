# MAT73.jl

**This package reads and writes MATLAB `.mat` files of version 7.3. It uses only Julia code.
It does not use the HDF5 C library. It also works inside a small compiled program.**

MATLAB writes version 7.3 files when you use `save -v7.3`.

## Example

```julia
using MAT73

f = matopen("results.mat")
keys(f)                                # the names of the variables
matclass(f, "A")                       # MAT_DOUBLE
matsize(f, "A")                        # [128, 128]

A     = matread(f, "A", Matrix{Float64})
flags = matread(f, "flags", Matrix{Bool})
z     = matread(f, "z", Matrix{ComplexF64})
label = matread(f, "label", String)

matwrite("out.mat", "A" => A, "flags" => flags, "label" => label)
```

## What this package covers

**It reads one file format only: the format built on HDF5.**

MATLAB has older formats, from version 4 to version 7. They use a different container. MAT.jl
already covers them in the Julia ecosystem. This package does not repeat that work.

Inside version 7.3 it reads numbers, true and false values, text, complex numbers and empty
arrays. It reads cell arrays, structs and objects. [The format](format.md) has the full list,
and the list of what it cannot do.

## Why you give the type

**You tell `matread` which type you expect. It does not guess.**

Think of a parcel with no label. You must say what is inside before you open it.

The reason is a compiler tool named `juliac`. It builds a small program from Julia code. It
uses the option `--trim=safe`. This option rejects any function that can return more than one
type. A file can hold many types. Therefore the caller states the type.

```julia
A = matread(f, "A", Matrix{Float64})
```

The package then does 3 checks against the file:

1. the kind of number, such as a whole number or a decimal number
2. the width in bytes
3. the sign, for whole numbers

If a check fails, the package stops with an error. It does not read the bytes as the wrong
type. This matters. A check on the width alone can read past the end of a smaller array. You
then get numbers that look real but are not.

Use [`matclass`](@ref) first if you do not know what is in the file. It gives
`MAT_UNSUPPORTED` for a type this package does not read. It does not stop with an error, so
you can look through a whole file safely.

## Order of the dimensions

**You get the same array that MATLAB shows. Nothing is turned around. Nothing is copied to
reorder it.**

Two facts cancel each other:

1. MATLAB and Julia both put the first dimension down the columns.
2. The file keeps the list of dimensions in the opposite order.

So the package fills a Julia array in file order, under the reversed dimensions. The result
matches MATLAB.

## This package or MAT.jl

**Use MAT.jl unless you need one of 2 things.**

MAT.jl is the general choice. It reads every MATLAB version. It builds full values for tables,
dates and other MATLAB types. It reaches version 7.3 through the HDF5 C library.

Use MAT73.jl when you need:

1. no C library in your list of dependencies, or
2. to read a `.mat` file inside a small compiled program.

The tests compare this package against MAT.jl on files that MATLAB wrote. The two agree where
they overlap.
