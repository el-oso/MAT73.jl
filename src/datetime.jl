# MATLAB dates.
#
# A MATLAB `datetime` is an object like any other. Its class and its properties read through
# the normal path. What this file adds is the one rule that turns a property into a date: the
# `data` property counts milliseconds from 1 January 1970.
#
# MathWorks does not publish that rule either. It matches what MAT.jl does.

"The MATLAB class name for a date."
const DATETIME_CLASS = "datetime"

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
