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

"The MATLAB class name for text drawn from a fixed set of choices."
const CATEGORICAL_CLASS = "categorical"

"The MATLAB class name for a set of named columns of equal length."
const TABLE_CLASS = "table"

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

Read a MATLAB `string` or `categorical` array.

MATLAB does not keep a `string` as text beside the array. It keeps one block of numbers that
holds, in order: a version, the number of dimensions, the dimensions, the length of each
piece of text, and then all the text as 16-bit units.

A `categorical` keeps a list of the choices and one number per element, counting from 1 into
that list. You get the text of the choice.

A `char` array is a different thing; use the `String` or `Array{Char,N}` method for one of
those.
"""
function matread(f::MatFile, key, ::Type{Array{String, N}}) where {N}
    name = keyname(key)
    class = matobjectclass(f, key)
    class == CATEGORICAL_CLASS && return categorical(f, key, Val(N))
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

"""
The numbers of a `categorical`, one per element, counting from 1 into the list of choices.
MATLAB stores them as the smallest whole number type that holds the count, so the width is
settled by a ladder rather than by the caller.
"""
function categoricalcodes(f::MatFile, addr::Int, ::Type{Array{Int, N}}) where {N}
    oi = objinfo(f.h5, addr)
    r = MatRef(addr)
    oi.dt_size == 1 && return Int.(matread(f, r, Array{UInt8, N}))
    oi.dt_size == 2 && return Int.(matread(f, r, Array{UInt16, N}))
    oi.dt_size == 4 && return Int.(matread(f, r, Array{UInt32, N}))
    return Int.(matread(f, r, Array{UInt64, N}))
end

"""
The choices of a `categorical`. MATLAB holds them either as a cell of `char`, or, in a file
a newer release wrote, as a `string` array.
"""
function categorychoices(f::MatFile, addr::Int)
    r = MatRef(addr)
    matobjectclass(f, r) == STRING_CLASS && return vec(matread(f, r, Matrix{String}))
    refs = vec(matread(f, r, Matrix{MatRef}))
    out = Vector{String}(undef, length(refs))
    for i in eachindex(refs)
        out[i] = matread(f, refs[i], String)
    end
    return out
end

"Turn the numbers of a `categorical` into the text of the choice each one names."
function categorical(f::MatFile, key, ::Val{N}) where {N}
    name = keyname(key)
    oi = objinfo(f.h5, address(f, key))
    choices = categorychoices(f, objectproperty(f, oi, "categoryNames"))
    codes = categoricalcodes(f, objectproperty(f, oi, "codes"), Array{Int, N})
    out = Array{String, N}(undef, size(codes))
    for i in eachindex(codes)
        c = codes[i]
        # MATLAB shows an element with no choice as <undefined> and stores it as a zero.
        iszero(c) && error("variable \"", name, "\" holds an element with no category")
        (c >= 1 && c <= length(choices)) ||
            error("variable \"", name, "\" names category ", c, ", which does not exist")
        out[i] = choices[c]
    end
    return out
end

"""
The columns of a MATLAB `table`, in the order the given names ask for.

A table keeps its column names in `varnames` and its columns in `data`, so a name is matched
against `varnames` and the column at the same place is returned.
"""
function tablecolumns(f::MatFile, key, names::Vector{String})
    class = matobjectclass(f, key)
    class == TABLE_CLASS ||
        error("variable \"", keyname(key), "\" is not a MATLAB table; its class is \"", class, "\"")

    oi = objinfo(f.h5, address(f, key))
    varnames = vec(matread(f, MatRef(objectproperty(f, oi, "varnames")), Matrix{MatRef}))
    data = vec(matread(f, MatRef(objectproperty(f, oi, "data")), Matrix{MatRef}))
    out = Vector{MatRef}(undef, length(names))
    for i in eachindex(names)
        at = 0
        for j in eachindex(varnames)
            matread(f, varnames[j], String) == names[i] || continue
            at = j
            break
        end
        iszero(at) && error("this MATLAB table has no column named \"", names[i], "\"")
        at <= length(data) || error("column \"", names[i], "\" has no values in this table")
        out[i] = data[at]
    end
    return out
end

"""
    matread(f, name, NamedTuple{names,types}) -> NamedTuple

Read a MATLAB `table` as a named tuple of columns.

You state the column names and the type of each column. Each type is the type of a whole
column, so it is a `Vector`:

```julia
t = matread(f, "flights", NamedTuple{
    (:FlightNum, :Customer),
    Tuple{Vector{Float64}, Vector{String}},
})
t.Customer
```

You may ask for a subset of the columns, in any order. A name that the table does not have
stops with an error.

A named tuple of vectors is a column table, so anything that reads the Tables.jl interface
takes the result as it is. No dependency is needed for that.
"""
@generated function matread(f::MatFile, key, ::Type{NT}) where {NT <: NamedTuple}
    names = String[String(n) for n in fieldnames(NT)]
    reads = Expr[]
    for T in fieldtypes(NT)
        T <: Vector ||
            return :(error("a table column must be asked for as a Vector type, not ", $T))
        # A column is stored as one column of a matrix, so the read is a matrix read.
        push!(reads, :(vec(matread(f, columns[$(length(reads) + 1)], Matrix{$(eltype(T))}))))
    end
    return quote
        columns = tablecolumns(f, key, $names)
        return NT(($(reads...),))
    end
end
