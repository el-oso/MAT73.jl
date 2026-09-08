# MATLAB's own classes.
#
# A `datetime` or a `string` is an object like any other. Its class and its properties read
# through the normal path. What this file adds is the rule that turns those properties into a
# value, one rule for each class.
#
# MathWorks does not publish these rules. They match what MAT.jl does.

"The MATLAB class name for a date."
const DATETIME_CLASS = "datetime"

"The MATLAB class name for a piece of text held as a `string`, not as `char`."
const STRING_CLASS = "string"

"""
Turn a count of milliseconds from 1 January 1970 into a `DateTime`.

MATLAB may store the count as a complex number. The real part holds the milliseconds. The
imaginary part holds a smaller step than a millisecond, which a `DateTime` cannot keep, so it
is dropped.
"""
@inline millisecondsdate(ms::Real) = DateTime(1970, 1, 1) + Millisecond(round(Int64, ms))
@inline millisecondsdate(ms::Complex) = millisecondsdate(real(ms))

"""
    matread(f, name, Array{DateTime,N}) -> Array{DateTime,N}

Read a MATLAB `datetime` array.

MATLAB keeps a date as a count of milliseconds from 1 January 1970. This reads that count and
gives you a `DateTime`.

A time zone on the MATLAB side is not applied. The result is the date as MATLAB stored it.
"""
function matread(f::MatFile, key, ::Type{Array{DateTime, N}}) where {N}
    name = keyname(key)
    class = matobjectclass(f, key)
    class == DATETIME_CLASS ||
        error("variable \"", name, "\" is not a MATLAB datetime; its class is \"", class, "\"")

    addr = objectproperty(f, objinfo(f.h5, address(f, key)), "data")
    values = matread(f, MatRef(addr), Array{ComplexF64, N})
    out = Array{DateTime, N}(undef, size(values))
    for i in eachindex(values)
        out[i] = millisecondsdate(values[i])
    end
    return out
end

"""
    matread(f, name, Array{String,N}) -> Array{String,N}

Read a MATLAB `string` array.

MATLAB does not keep a `string` as text beside the array. It keeps one block of numbers that
holds, in order: a version, the number of dimensions, the dimensions, the length of each
piece of text, and then all the text as 16-bit units.

This reads that block. A `char` array is a different thing; use the `String` or
`Array{Char,N}` method for one of those.
"""
function matread(f::MatFile, key, ::Type{Array{String, N}}) where {N}
    name = keyname(key)
    class = matobjectclass(f, key)
    class == STRING_CLASS ||
        error("variable \"", name, "\" is not a MATLAB string; its class is \"", class, "\"")

    addr = objectproperty(f, objinfo(f.h5, address(f, key)), "any")
    raw = vec(matread(f, MatRef(addr), Matrix{UInt64}))
    length(raw) >= 2 || error("variable \"", name, "\" holds no string data")
    isone(raw[1]) ||
        error("variable \"", name, "\" uses string layout version ", Int(raw[1]), ", not 1")

    nd = Int(raw[2])
    nd == N || error("variable \"", name, "\" has rank ", nd, ", not ", N)
    dims = ntuple(k -> Int(raw[2 + k]), Val(N))
    total = 1
    for k in 1:N
        total *= dims[k]
    end

    # Lengths first, then the text of every piece back to back.
    lengths = raw[(3 + nd):(2 + nd + total)]
    units = reinterpret(UInt16, reinterpret(UInt8, raw[(3 + nd + total):end]))
    out = Array{String, N}(undef, dims)
    from = 1
    for i in eachindex(out)
        to = from + Int(lengths[i]) - 1
        to <= length(units) || error("variable \"", name, "\" ends before its text does")
        out[i] = transcode(String, units[from:to])
        from = to + 1
    end
    return out
end
