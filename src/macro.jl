# A short way to read several variables at once, without giving up the fixed return type.
#
# The macro writes one ordinary typed read for each line you list. Every type is written out in
# the code the macro produces, so the result works inside a small compiled program. The macro
# saves typing. It does not change what the reads do.

"""
What a [`@matload`](@ref) block reads from.

- An open file, used as it stands, so a caller that already has one does not open it twice.
- A path, which is opened.
- A file and a mark into it, which makes every path in the block relative to that mark.
"""
matsource(f::MatFile) = f
matsource(path::String) = matopen(path)
matsource(t::Tuple{MatFile, MatRef}) = t

"The file a source reads from."
sourcefile(f::MatFile) = f
sourcefile(t::Tuple{MatFile, MatRef}) = t[1]

"Where a path in the block starts from, resolved to something the typed reads accept."
sourcekey(f::MatFile, path::String) = MatPath(lookup(f, path), path)
sourcekey(t::Tuple{MatFile, MatRef}, path::String) = MatPath(lookup(t[1], t[2], path), path)

"""
    @matload f begin
        A::Matrix{Float64}
        n::Int64
        label::String
        gain = "cfg/gain"::Float64
    end

Read several variables at once and give back a named tuple.

The first argument says where to read from: an open file, a path, or a file and a mark. A path
is opened once for the whole block. With `f, ref` every path in the block starts at `ref`
instead of at the top of the file.

```julia
runs = matread(f, "runs", Matrix{MatRef})

v = @matload f, runs[1] begin
    count = "count"::Float64
    values = "inner/values"::Matrix{Float64}
end
```


```julia
v = @matload "results.mat" begin
    A::Matrix{Float64}
    n::Int64
end
v.A
v.n

f = matopen("results.mat")       # the same, from a file you already have open
v = @matload f begin
    A::Matrix{Float64}
end
```

Each line becomes one ordinary read with the type written out. So the result **works inside a
small compiled program**, unlike `matread(f, name)` without a type.

Write one line for each variable:

- `name::Type` reads the variable called `name`.
- `name = "a/path"::Type` reads that path and calls the result `name`. Use it for a field of a
  struct, or a property of an object.

A plain number type, such as `Int64`, means a MATLAB scalar. You get the single value. Ask for
`Matrix{Int64}` if you want the 1x1 array.
"""
macro matload(file, block)
    lines = block isa Expr && block.head === :block ? block.args : Any[block]
    fields = Any[]
    # The file expression is evaluated once and held in a local. Repeating it per field would
    # open a path once for every variable read.
    src = gensym("matload")
    for line in lines
        line isa LineNumberNode && continue
        name = nothing
        path = nothing
        type = nothing
        if line isa Expr && line.head === :(::) && length(line.args) == 2 && line.args[1] isa Symbol
            name = line.args[1]
            path = String(name)
            type = line.args[2]
        elseif line isa Expr && line.head === :(=) && line.args[1] isa Symbol
            rhs = line.args[2]
            if rhs isa Expr && rhs.head === :(::) && rhs.args[1] isa AbstractString
                name = line.args[1]
                path = String(rhs.args[1])
                type = rhs.args[2]
            end
        end
        isnothing(name) && throw(
            ArgumentError(
                "@matload takes lines of the form `name::Type` or `name = \"a/path\"::Type`, not `$line`"
            )
        )
        push!(
            fields,
            Expr(
                :(=), name,
                :($matread($sourcefile($src), $sourcekey($src, $path), $(esc(type)))),
            ),
        )
    end
    isempty(fields) && throw(ArgumentError("@matload needs at least one variable"))
    return Expr(
        :block,
        Expr(:local, Expr(:(=), src, :($matsource($(esc(file)))))),
        Expr(:tuple, fields...),
    )
end
