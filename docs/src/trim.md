# Small compiled programs

**A tool named `juliac` turns Julia code into a small program. This package is written to work
inside one.**

Think of packing for a trip with one small bag. You take only the clothes you will wear. You
leave the rest at home.

`juliac` does the same with code. The option `--trim=safe` keeps only the code the program can
reach. It then refuses to build if it cannot work out which function a call will use. A file
reader normally decides that while it runs. So the design of this package had to change.

## How to use it

The program needs a `@main` function at the top level of the file. `juliac` copies the file
into a fresh place, so a `module` around it does not work.

```julia
using MAT73

function (@main)(args::Vector{String})::Cint
    out = Core.stdout                     # not Base.stdout
    a = matread(matopen(args[1]), args[2], Matrix{Float64})
    println(out, "n=", length(a), " sum=", sum(a))
    return Cint(0)
end
```

Use `Core.stdout`. `Base.stdout` can hold any kind of output, so the build cannot work it out.

Build it:

```
julia --project=. \
  $(julia -e 'print(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac.jl"))') \
  --output-exe matsum --experimental --trim=safe entry.jl < /dev/null
```

**The `< /dev/null` part is needed.** Without it the Julia launcher can fail while it reads
its input, after the build has already worked. That looks like a broken build. It is not.

The file `juliac/build.jl` in this repository does all of the above. It then runs the program
and compares the answer against normal Julia code.

## What this costs the interface

**Three parts of the interface look the way they do because of this tool.**

1. **`matread` takes the type.** A function may not return more than one type. The type of a
   variable comes from the file. So the caller states it.
2. **`matsize` returns a `Vector{Int}`.** The number of dimensions comes from the file. A
   tuple would then have no fixed length.
3. **A cell array returns marks.** The items have mixed types. One mark type covers them all.

Two rules inside the code follow from the same tool. They are worth knowing if you read the
source.

- The list of filters is a fixed-size group of numbers. It is not a list of filter objects. A
  container whose length or contents come from the file cannot be worked out in advance.
- No helper function reads a variable that was set inside an `if` and then used inside an
  inner function. Julia puts such a variable in a box. The build then loses track of its type.

## Two checks, not one

**Both checks run in the build service. They cover different things.**

`trim/trimcheck.jl` runs the compiler check on every entry point.

- It uses the same compiler step the real build uses.
- It applies the same patches to the base library.
- It therefore reports the same problems, including problems inside cleanup functions.
- A failure here is a failure of the real build.
- It lives outside the test setup. It needs a part of Julia 1.12, and this package supports
  Julia 1.10.

`juliac/build.jl` builds a real program and runs it.

- It links the program. The first check does not.
- It starts the program. The first check does not.
- It keeps every start-up function in every loaded package. The first check keeps only the one
  function you name.

Both gaps have caused real failures in code that passed the first check:

1. a library that looks up files on disk when it starts, and stops the program before it runs
2. a call into a C library, written in a form that passes the check and then fails at run time

Run both:

```
julia --project=trim -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=trim trim/trimcheck.jl
julia --project=. juliac/build.jl
```

## Dependencies

**This package depends on 2 things only: `Mmap` and `ChunkCodecLibZlib`.**

`ChunkCodecLibZlib` calls the zlib library, for compressed data. On Julia 1.12 that wrapper is
a small piece of the standard library. It names the library by a fixed name. It does not look
up any files on disk.

So a small compiled program finds zlib through a path that `juliac` already writes into it. It
gains no new outside dependency. The name `libz.so.1` does not even appear in the list of
libraries the program needs.

**This is why new dependencies need care here.** Some wrappers look up their library on disk
when the program starts. If the program cannot find it, the program stops before your code
runs.
