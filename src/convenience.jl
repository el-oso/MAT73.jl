# The short way to read a file, for ordinary Julia code.
#
# These functions work out the type from the file and return whatever they find. That means
# their return type is not fixed, so they cannot be used inside a small compiled program. The
# rest of the package can: a program that never calls these functions does not carry them, and
# the build discards them.
#
# Everything here is built on the typed reads. It adds no new parsing.

"""
The Julia element type for a MATLAB type name. Used for an empty array, whose stored bytes
are its dimensions rather than its contents, so the datatype in the file says nothing about
the type of the array. MATLAB makes an empty array `double` unless it says otherwise.
"""
function classelementtype(c::MatClass)
    c == MAT_SINGLE && return Float32
    c == MAT_INT8 && return Int8
    c == MAT_INT16 && return Int16
    c == MAT_INT32 && return Int32
    c == MAT_INT64 && return Int64
    c == MAT_UINT8 && return UInt8
    c == MAT_UINT16 && return UInt16
    c == MAT_UINT32 && return UInt32
    c == MAT_UINT64 && return UInt64
    c == MAT_LOGICAL && return Bool
    c == MAT_CHAR && return Char
    return Float64
end

"Work out the Julia element type of a dataset from the notes beside it."
function elementtype(oi::ObjInfo, name::String)
    oi.int_decode == 1 && return Bool
    if oi.dt_class == DT_FLOAT
        oi.dt_size == 8 && return Float64
        oi.dt_size == 4 && return Float32
    elseif oi.dt_class == DT_FIXED
        if oi.dt_signed
            oi.dt_size == 1 && return Int8
            oi.dt_size == 2 && return Int16
            oi.dt_size == 4 && return Int32
            oi.dt_size == 8 && return Int64
        else
            oi.dt_size == 1 && return UInt8
            oi.dt_size == 2 && return UInt16
            oi.dt_size == 4 && return UInt32
            oi.dt_size == 8 && return UInt64
        end
    elseif oi.dt_class == DT_COMPOUND
        oi.dt_size == 16 && return ComplexF64
        oi.dt_size == 8 && return ComplexF32
    elseif oi.dt_class == DT_REFERENCE
        return MatRef
    end
    return error(
        "variable \"", name, "\" has an HDF5 datatype this package does not read: class ",
        oi.dt_class, ", ", oi.dt_size, " bytes"
    )
end

# The number of dimensions comes from the file, so the typed read is reached through a ladder.
function readrank(f::MatFile, key, ::Type{T}, n::Int) where {T}
    iszero(n) && return matread(f, key, Array{T, 0})
    n == 1 && return matread(f, key, Array{T, 1})
    n == 2 && return matread(f, key, Array{T, 2})
    n == 3 && return matread(f, key, Array{T, 3})
    n == 4 && return matread(f, key, Array{T, 4})
    n == 5 && return matread(f, key, Array{T, 5})
    n == 6 && return matread(f, key, Array{T, 6})
    n == 7 && return matread(f, key, Array{T, 7})
    return matread(f, key, Array{T, 8})
end

"""
    matread(f, name)

Read a variable and give back whatever it holds. This works out the type from the file.

```julia
f = matopen("results.mat")
A = matread(f, "A")          # a Matrix{Float64}
s = matread(f, "s")          # a Dict, for a struct
```

The result type is not fixed, so **this cannot be used inside a small compiled program**. Give
the type instead when you need that: `matread(f, "A", Matrix{Float64})`.

What you get:

| in the file | you get |
|---|---|
| a number array | an `Array` of the matching type |
| `logical` | an `Array{Bool}` |
| text of one row | a `String` |
| text of any other shape | an `Array{Char}` |
| a cell array | an `Array{Any}`, with each item read |
| a struct | a `Dict{String,Any}` |
| an object | a `Dict{String,Any}` of its properties |
"""
function matread(f::MatFile, key)
    oi = objinfo(f.h5, address(f, key))
    name = keyname(key)

    # An object and a struct both read as a set of named values, except for the MATLAB types
    # this package knows a rule for.
    if !iszero(oi.mobject)
        if matobjectclass(f, key) == DATETIME_CLASS
            data = objinfo(f.h5, objectproperty(f, oi, "data"))
            return readrank(f, key, DateTime, data.nd)
        end
        out = Dict{String, Any}()
        for prop in objectkeys(f, oi)
            out[prop] = matread(f, MatRef(objectproperty(f, oi, prop)))
        end
        return out
    end
    if isgroup(oi)
        oi.msparse < 0 || error("variable \"", name, "\" is sparse, which is not read")
        out = Dict{String, Any}()
        names, addrs = groupentries(f.h5, oi)
        for i in eachindex(names)
            out[names[i]] = matread(f, MatRef(addrs[i]))
        end
        return out
    end

    # An empty array stores its dimensions in place of its contents, so both the rank and the
    # element type come from elsewhere: the stored list, and the MATLAB type name.
    if oi.mempty
        dims = matsize(f.h5, oi)
        return readrank(f, key, classelementtype(classof(oi.mclass)), length(dims))
    end

    # Text of one row is a string; any other shape is an array of characters.
    if oi.int_decode == 2
        dims = matsize(f.h5, oi)
        (length(dims) >= 2 && dims[1] == 1) && return matread(f, key, String)
        return readrank(f, key, Char, oi.nd)
    end

    values = readrank(f, key, elementtype(oi, name), oi.nd)
    # A cell array holds marks; follow each one so the caller sees the values.
    eltype(values) === MatRef || return values
    return map(r -> matread(f, r), values)
end

"""
    matread(path) -> Dict{String,Any}

Open a file and read every variable in it.

```julia
d = matread("results.mat")
d["A"]
```

The result type is not fixed, so **this cannot be used inside a small compiled program**.

The two names MATLAB uses for itself, `#refs#` and `#subsystem#`, are left out.
"""
function matread(path::String)
    f = matopen(path)
    out = Dict{String, Any}()
    for name in keys(f)
        startswith(name, "#") && continue
        out[name] = matread(f, name)
    end
    return out
end
