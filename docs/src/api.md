# Functions and types

## Reading, the short way

These work out the type from the file. They cannot be used inside a small compiled program.

```@docs
matread(::String)
matread(::MAT73.MatFile, ::Any)
```

## Reading several variables at once

```@docs
@matload
MAT73.matfield
```

## Reading, with the type

```@docs
matopen
matread(::String, ::String, ::Type)
matread(::MAT73.MatFile, ::MAT73.MatRef, ::String, ::Type)
matref
matclass
matsize
matkeys
matobjectclass
matread
MAT73.MatFile
MAT73.MatClass
MAT73.MatRef
```

## Writing

```@docs
matwrite
MAT73.MatWriter
push!(::MAT73.MatWriter, ::String, ::Any)
```

**Use `matwrite(path, pairs...)` for the simple case.**

For a set of variables built in a loop, collect them first. Addresses inside the file depend
on the size of every variable. So nothing is written until the end.

```julia
w = MatWriter()
for (name, value) in results
    push!(w, name, value)
end
matwrite("out.mat", w)
```
