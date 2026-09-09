# A short way to read several variables at once, without giving up the fixed return type.
#
# The macro writes one ordinary typed read for each line you list. Every type is written out in
# the code the macro produces, so the result works inside a small compiled program. The macro
# saves typing. It does not change what the reads do.

"""
The file a [`@matload`](@ref) block reads from. A path is opened. An open file is used as it
stands, so a caller that already has one does not open it twice.
"""
matsource(f::MatFile) = f
matsource(path::String) = matopen(path)

"""
Read one field for [`@matload`](@ref). The 3 methods pick the right read from the type you
asked for, at compile time.

A plain number type means a MATLAB scalar, which is a 1x1 array in the file. The single value
comes back, not the array.
"""
function matfield(f::MatFile, path::String, ::Type{Array{T, N}}) where {T, N}
    return matread(f, path, Array{T, N})
end

matfield(f::MatFile, path::String, ::Type{String}) = matread(f, path, String)

function matfield(f::MatFile, path::String, ::Type{T}) where {T}
    a = matread(f, path, Matrix{T})
    isone(length(a)) ||
        error("variable \"", path, "\" holds ", length(a), " values, not 1; ask for an array type")
    return a[1]
end

"""
    @matload f begin
        A::Matrix{Float64}
        n::Int64
        label::String
        gain = "cfg/gain"::Float64
    end

Read several variables at once and give back a named tuple.

The first argument is an open file or a path. A path is opened once for the whole block.

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
        push!(fields, Expr(:(=), name, :($matfield($src, $path, $(esc(type))))))
    end
    isempty(fields) && throw(ArgumentError("@matload needs at least one variable"))
    return Expr(
        :block,
        Expr(:local, Expr(:(=), src, :($matsource($(esc(file)))))),
        Expr(:tuple, fields...),
    )
end
