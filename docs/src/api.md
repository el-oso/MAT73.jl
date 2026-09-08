# API

## Reading

```@docs
matopen
matclass
matsize
matread
MAT73.MatFile
MAT73.MatClass
```

## Writing

```@docs
matwrite
MAT73.MatWriter
```

`matwrite(path, pairs...)` covers the common case. For anything built up in a loop, collect
into a [`MAT73.MatWriter`](@ref) with `push!(w, name, value)` and hand it over at the end;
addresses cannot be assigned until every variable's size is known, so nothing reaches the file
before then.

```julia
w = MatWriter()
for (name, value) in results
    push!(w, name, value)
end
matwrite("out.mat", w)
```
