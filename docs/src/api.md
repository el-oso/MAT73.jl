# Functions and types

## Reading

```@docs
matopen
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
