# The reading API. A caller states the type it expects, so every read has a concrete return
# type — `--trim=safe` rejects a call whose return type is only known from the file.

"""
    MatClass

The MATLAB type of a variable, taken from the note beside it in the file.

`MAT_UNSUPPORTED` covers everything this package does not read. So you can look through a
whole file and skip what you cannot use. Nothing stops with an error.
"""
@enum MatClass::UInt8 begin
    MAT_UNSUPPORTED
    MAT_DOUBLE
    MAT_SINGLE
    MAT_INT8
    MAT_INT16
    MAT_INT32
    MAT_INT64
    MAT_UINT8
    MAT_UINT16
    MAT_UINT32
    MAT_UINT64
    MAT_LOGICAL
    MAT_CHAR
    MAT_CELL
    MAT_STRUCT
end

# A static ladder rather than a lookup table: the result is then a compile-time-known enum
# rather than a value fetched from a container.
function classof(s::String)
    s == "double" && return MAT_DOUBLE
    s == "single" && return MAT_SINGLE
    s == "int8" && return MAT_INT8
    s == "int16" && return MAT_INT16
    s == "int32" && return MAT_INT32
    s == "int64" && return MAT_INT64
    s == "uint8" && return MAT_UINT8
    s == "uint16" && return MAT_UINT16
    s == "uint32" && return MAT_UINT32
    s == "uint64" && return MAT_UINT64
    s == "logical" && return MAT_LOGICAL
    s == "char" && return MAT_CHAR
    s == "cell" && return MAT_CELL
    s == "struct" && return MAT_STRUCT
    return MAT_UNSUPPORTED
end

"""
    MatFile

An open MATLAB file, with the names of its variables and the place of each one.

Make one with [`matopen`](@ref).
"""
struct MatFile
    h5::H5File
    names::Vector{String}
    addrs::Vector{Int}
    # The subsystem is parsed on first use and kept here. A vector of at most one element is
    # the cache: an immutable file object with a mutable field would not be concrete.
    mcos::Vector{McosState}
end

"""
Read an array at a reference, skipping the MATLAB class checks. Used for the subsystem, whose
cells are not MATLAB values in their own right. The rank is given rather than taken from the
file so that the return type is concrete.
"""
function readarray(f::MatFile, r::MatRef, ::Type{Array{T, N}}) where {T, N}
    oi = objinfo(f.h5, r.addr)
    oi.nd == N || error("subsystem cell has rank ", oi.nd, ", not ", N)
    return readvalues(f, oi, "subsystem cell", Array{T, N})
end

"""
    matopen(path) -> MatFile

Open a MATLAB `.mat` file of version 7.3 and read the list of variable names in it.
"""
function matopen(path::String)
    h5 = open_h5(path)
    names, addrs = rootentries(h5)
    return MatFile(h5, names, addrs, McosState[])
end

Base.keys(f::MatFile) = copy(f.names)

"""
Address of the object at `path`. A path may descend through groups with `/`, which is how a
struct's fields are reached: `matread(f, "s/a", Matrix{Float64})`.
"""
function lookup(f::MatFile, path::String)
    names = f.names
    addrs = f.addrs
    addr = -1
    for part in split(path, '/'; keepempty = false)
        found = -1
        for i in eachindex(names)
            if names[i] == part
                found = addrs[i]
                break
            end
        end
        if found < 0 && addr >= 0
            # Not a group member: a MATLAB object's properties live in the subsystem, and
            # are reached by the same path syntax as a struct's fields.
            oi = objinfo(f.h5, addr)
            iszero(oi.mobject) && error("no variable or field named \"", path, "\" in this file")
            found = objectproperty(f, oi, String(part))
        end
        found >= 0 || error("no variable or field named \"", path, "\" in this file")
        addr = found
        names, addrs = groupentries(f.h5, addr)
    end
    addr >= 0 || error("empty path")
    return addr
end

"The object ids a `classdef` variable refers to, and the subsystem it refers into."
function objectids(f::MatFile, oi::ObjInfo)
    oi.nd == 2 || error("a MATLAB object variable should be a 1xN index array, not rank ", oi.nd)
    return mcos_objectids(vec(readvalues(f, oi, "object", Matrix{UInt32})))
end

"""
    matobjectclass(f, name) -> String

Give the full class name of a MATLAB object, such as `TestClasses.BasicClass`. The name
includes the namespace.

Give an empty string if the variable is not an object.

If the variable points to more than one object, this describes the first one.
"""
function matobjectclass(f::MatFile, key)
    oi = objinfo(f.h5, address(f, key))
    iszero(oi.mobject) && return ""
    ids = objectids(f, oi)
    isempty(ids) && return oi.mclass
    t = mcos(f).tables
    name = mcos_classname(t, mcos_objectclass(t, ids[1]))
    return isempty(name) ? oi.mclass : name
end

"""
A dynamic property is itself an object of class `meta.DynamicProperty`: its `DynamicName_`
holds the name the property was given, and its `DynamicValue_` the value. This pairs each
name with the address its value lives at.
"""
function dynamicproperties(f::MatFile, objid::Int)
    state = mcos(f)
    t = state.tables
    out = Tuple{String, Int}[]
    for propid in mcos_dynamicprops(t, objid)
        name = ""
        value = -1
        for (nameidx, kind, v) in mcos_props(t, propid)
            kind == MCOS_CELL || continue
            (nameidx >= 1 && nameidx <= length(t.names)) || continue
            i = v + 3
            (i >= 1 && i <= length(state.cells)) || continue
            if t.names[nameidx] == "DynamicName_"
                name = matread(f, state.cells[i], String)
            elseif t.names[nameidx] == "DynamicValue_"
                value = state.cells[i].addr
            end
        end
        (!isempty(name) && value >= 0) && push!(out, (name, value))
    end
    return out
end

"Property names of a MATLAB object: those declared by its class, then any added with `addprop`."
function objectkeys(f::MatFile, oi::ObjInfo)
    ids = objectids(f, oi)
    isempty(ids) && return String[]
    t = mcos(f).tables
    out = String[]
    for (nameidx, _, _) in mcos_props(t, ids[1])
        (nameidx >= 1 && nameidx <= length(t.names)) && push!(out, t.names[nameidx])
    end
    for (name, _) in dynamicproperties(f, ids[1])
        push!(out, name)
    end
    return out
end

"""
Address of one property of a MATLAB object. Only properties whose value is stored in the
subsystem's cell array can be addressed; an enumeration or an inline attribute is a value, not
an object, so it has no address.
"""
function objectproperty(f::MatFile, oi::ObjInfo, prop::String)
    ids = objectids(f, oi)
    isempty(ids) && error("this MATLAB object refers to no instance")
    state = mcos(f)
    t = state.tables
    for (nameidx, kind, value) in mcos_props(t, ids[1])
        (nameidx >= 1 && nameidx <= length(t.names)) || continue
        t.names[nameidx] == prop || continue
        kind == MCOS_CELL ||
            error("property \"", prop, "\" is stored inline, not as a value this package can address")
        # Index 0 names the third cell: the first two hold the metadata and a placeholder.
        i = value + 3
        (i >= 1 && i <= length(state.cells)) || error("property \"", prop, "\" points outside the subsystem")
        return state.cells[i].addr
    end
    for (name, value) in dynamicproperties(f, ids[1])
        name == prop && return value
    end
    return error("no property named \"", prop, "\" on this MATLAB object")
end

"""
    matkeys(f, path) -> Vector{String}

Give the names inside a group.

- For a struct, these are the field names.
- For an object, these are the property names. Properties added with `addprop` are included.
- For an empty `path`, these are the variable names at the top level of the file.

The names come in file order. MATLAB may use a different order for the fields of a struct.
"""
function matkeys(f::MatFile, path::String)
    isempty(path) && return copy(f.names)
    addr = lookup(f, path)
    oi = objinfo(f.h5, addr)
    iszero(oi.mobject) || return objectkeys(f, oi)
    return groupentries(f.h5, oi)[1]
end

matkeys(f::MatFile, r::MatRef) = groupentries(f.h5, r.addr)[1]

"""
    matclass(f, name) -> MatClass

Give the MATLAB type of a variable.

Give `MAT_UNSUPPORTED` for a type this package does not read. This does not stop with an
error, so you can look through a whole file first.

An object and a sparse array both report `MAT_UNSUPPORTED`. Neither is a plain array. For an
object, use [`matobjectclass`](@ref) instead.
"""
function matclass(f::MatFile, key)
    oi = objinfo(f.h5, address(f, key))
    # A MATLAB object, or a sparse array, is not the plain class its attribute names.
    (iszero(oi.mobject) && oi.msparse < 0) || return MAT_UNSUPPORTED
    return classof(oi.mclass)
end

# A variable is named by a path or reached through a reference; both resolve to an address.
@inline address(f::MatFile, path::String) = lookup(f, path)
@inline address(::MatFile, r::MatRef) = r.addr

# What to call the object in an error message.
@inline keyname(path::String) = path
@inline keyname(r::MatRef) = "referenced object"

"""
    matsize(f, name) -> Vector{Int}

Give the size of a variable, in the order MATLAB uses.

The result is a `Vector`, not a tuple. The number of dimensions comes from the file, so a
tuple would have no fixed length.
"""
function matsize(f::MatFile, key)
    return matsize(f.h5, objinfo(f.h5, address(f, key)))
end

function matsize(h5::H5File, oi::ObjInfo)
    if oi.mempty
        # An empty array stores its own dimensions as the dataset's contents, so that a
        # 0x3 keeps its shape rather than collapsing to 0x0.
        n = oi.nd >= 1 ? oi.dims[1] : 0
        dims = Vector{Int}(undef, n)
        for k in 1:n
            dims[k] = Int(readuint(h5.buf, oi.data_off + (k - 1) * oi.dt_size, oi.dt_size))
        end
        return dims
    end
    dims = Vector{Int}(undef, oi.nd)
    for k in 1:oi.nd
        dims[k] = matdim(oi.dims, k, oi.nd)
    end
    return dims
end

# What an on-disk datatype must look like to be read as `T`. Both the class and the width are
# checked: a size-only check reads past the dataset extent and returns garbage.
@inline dtclass(::Type{<:AbstractFloat}) = DT_FLOAT
@inline dtclass(::Type{<:Integer}) = DT_FIXED
@inline dtclass(::Type{<:Complex}) = DT_COMPOUND
@inline dtclass(::Type{MatRef}) = DT_REFERENCE

function checkdatatype(oi::ObjInfo, ::Type{T}, name::String) where {T}
    want = dtclass(T)
    oi.dt_class == want ||
        error("variable \"", name, "\" has HDF5 datatype class ", oi.dt_class, ", not ", want)
    oi.dt_size == sizeof(T) ||
        error("variable \"", name, "\" stores ", oi.dt_size, "-byte elements, not ", sizeof(T))
    if want == DT_FIXED
        oi.dt_signed == (T <: Signed) ||
            error("variable \"", name, "\" has the opposite signedness to ", T)
    end
    # MATLAB stores logical and char as plain integers, so only the attribute separates them
    # from a numeric array of the same width.
    if T === Bool
        oi.int_decode == 1 || error("variable \"", name, "\" is not a MATLAB logical array")
    else
        oi.int_decode == 1 && error("variable \"", name, "\" is a logical array; read it as Bool")
        oi.int_decode == 2 && error("variable \"", name, "\" is a char array; read it as String")
    end
    return nothing
end

# Little-endian element at a byte offset. `sizeof(T)` is a compile-time constant for a
# concrete `T`, so this ladder folds away.
@inline function fromuint(::Type{T}, u::UInt64) where {T}
    sizeof(T) == 8 && return reinterpret(T, u)
    sizeof(T) == 4 && return reinterpret(T, unsafe_trunc(UInt32, u))
    sizeof(T) == 2 && return reinterpret(T, unsafe_trunc(UInt16, u))
    return reinterpret(T, unsafe_trunc(UInt8, u))
end

@inline readelem(::Type{T}, b::Vector{UInt8}, off::Int) where {T} =
    fromuint(T, readuint(b, off, sizeof(T)))

# A MATLAB logical is a byte; any non-zero value is true. Reinterpreting the byte instead
# would produce a `Bool` outside its two valid values.
@inline readelem(::Type{Bool}, b::Vector{UInt8}, off::Int) = !iszero(readuint(b, off, 1))

# An object reference is the address of another object header in the same file.
@inline readelem(::Type{MatRef}, b::Vector{UInt8}, off::Int) = MatRef(Int(readuint(b, off, 8)))

# A complex dataset is a compound of two members laid out real then imaginary, which is also
# Julia's own layout, but reading the halves explicitly keeps this endian-correct.
@inline function readelem(::Type{Complex{T}}, b::Vector{UInt8}, off::Int) where {T}
    s = sizeof(T)
    return Complex(fromuint(T, readuint(b, off, s)), fromuint(T, readuint(b, off + s, s)))
end

# Its own function so `dims` is a plain argument. A local that is assigned in one branch and
# then captured by a closure is boxed, and the box reads infer `Any`, which `--trim=safe`
# rejects — the same shape whether the closure is `ntuple`'s or written by hand.
function emptyarray(::Type{Array{T, N}}, dims::Vector{Int}, name::String) where {T, N}
    length(dims) == N ||
        error("empty variable \"", name, "\" has rank ", length(dims), ", not ", N)
    return Array{T, N}(undef, ntuple(k -> dims[k], Val(N)))
end

"""
    matread(f, name, Array{T,N}) -> Array{T,N}

Read a variable as an array of `T` with `N` dimensions.

You state the type. This function does not guess it. It then checks the file against `T` in
3 ways: the kind of number, the width in bytes, and the sign. If a check fails, it stops with
an error. It does not read the bytes as the wrong type.

`T` can be:

- a number type, such as `Float64` or `Int32`
- `Bool`, for a MATLAB `logical` array
- `Complex{T}`, for a complex array
- `Char`, for text of any shape
- `MatRef`, for a cell array or a field of a struct array

Use the `String` method instead for one row of text.

`name` can be a path, such as `"s/a"`. It can also be a [`MatRef`](@ref).

The result matches what MATLAB shows. Nothing is turned around.
"""
function matread(f::MatFile, key, ::Type{Array{T, N}}) where {T, N}
    name = keyname(key)
    oi = objinfo(f.h5, address(f, key))
    iszero(oi.mobject) || error("variable \"", name, "\" is a MATLAB object, which is not read")
    oi.msparse < 0 || error("variable \"", name, "\" is sparse, which is not read")

    oi.mempty && return emptyarray(Array{T, N}, matsize(f.h5, oi), name)

    oi.nd == N || error("variable \"", name, "\" has rank ", oi.nd, ", not ", N)
    checkdatatype(oi, T, name)
    return readvalues(f, oi, name, Array{T, N})
end

"""
Read the elements of a dataset whose header has already been checked. Split out so that a
class stored as one type and returned as another — `char`, held as code units — can reuse the
layout handling without going through the datatype checks a second time.
"""
function readvalues(f::MatFile, oi::ObjInfo, name::String, ::Type{Array{T, N}}) where {T, N}
    out = Array{T, N}(undef, ntuple(k -> matdim(oi.dims, k, oi.nd), Val(N)))

    if oi.layout == LAYOUT_CHUNKED
        oi.chunk_btree >= 0 || error("variable \"", name, "\" is chunked but has no chunk index")
        return readchunked!(out, f.h5, oi)
    end
    (oi.layout == LAYOUT_COMPACT || oi.layout == LAYOUT_CONTIGUOUS) ||
        error("variable \"", name, "\" has no readable data layout")
    oi.data_off >= 0 || error("variable \"", name, "\" has no allocated storage")

    sz = sizeof(T)
    n = length(out)
    oi.data_size >= n * sz || error("stored extent is shorter than the dataspace")
    oi.data_off + n * sz <= length(f.h5.buf) || error("data extends past the end of the file")
    b = f.h5.buf
    off = oi.data_off
    for i in eachindex(out)
        out[i] = readelem(T, b, off + (i - 1) * sz)
    end
    return out
end

"""
    matread(f, name, Array{Char,N}) -> Array{Char,N}

Read MATLAB text of any shape, one item at a time.

MATLAB text with more than one row has no single string form. So you get an array. For one row
of text, use the `String` method instead.

MATLAB keeps text as 16-bit units. Each unit becomes one `Char`. One rare character needs 2
units in MATLAB, and it therefore arrives here as 2 items. The `String` method joins such a
pair correctly.
"""
function matread(f::MatFile, key, ::Type{Array{Char, N}}) where {N}
    name = keyname(key)
    oi = objinfo(f.h5, address(f, key))
    oi.int_decode == 2 || error("variable \"", name, "\" is not a MATLAB char array")
    oi.mempty && return emptyarray(Array{Char, N}, matsize(f.h5, oi), name)
    oi.nd == N || error("variable \"", name, "\" has rank ", oi.nd, ", not ", N)

    # The code units are read as the integer they are stored as, then widened one for one.
    if oi.dt_size == 1
        return map(Char, readvalues(f, oi, name, Array{UInt8, N}))
    elseif oi.dt_size == 2
        return map(Char, readvalues(f, oi, name, Array{UInt16, N}))
    end
    return error("variable \"", name, "\" stores ", oi.dt_size, "-byte characters")
end

"""
    matread(f, name, String) -> String

Read one row of MATLAB text as a `String`.

MATLAB keeps text as 16-bit units, or as bytes for plain text. This function handles both, and
joins any pair of units that stands for one character.

Text with more than one row has no single string form. This function stops with an error in
that case. It does not join the rows. Use the `Array{Char,N}` method instead.
"""
function matread(f::MatFile, key, ::Type{String})
    name = keyname(key)
    oi = objinfo(f.h5, address(f, key))
    oi.int_decode == 2 || error("variable \"", name, "\" is not a MATLAB char array")
    oi.mempty && return ""

    dims = matsize(f.h5, oi)
    # A char row vector may carry trailing singleton dimensions — libhdf5 writes MATLAB's
    # 1xN as 1xNx1 — and those say nothing about the shape, so only the first dimension
    # has to be 1 and the rest multiply out to the length.
    # Only scalars are interpolated here: printing the dimension vector would pull array
    # `show` into the call graph, and it is not statically resolvable.
    n = 1
    for k in 2:length(dims)
        n *= dims[k]
    end
    (length(dims) >= 2 && dims[1] == 1) ||
        error(
        "variable \"", name, "\" is not a 1xN char array; it has rank ", length(dims),
        " and first dimension ", dims[1]
    )
    b = f.h5.buf
    off = oi.data_off
    oi.data_off >= 0 || error("variable \"", name, "\" has no allocated storage")
    if oi.dt_size == 1
        return String(b[(off + 1):(off + n)])
    elseif oi.dt_size == 2
        units = Vector{UInt16}(undef, n)
        for i in 1:n
            units[i] = unsafe_trunc(UInt16, readuint(b, off + (i - 1) * 2, 2))
        end
        return transcode(String, units)
    end
    return error("variable \"", name, "\" stores ", oi.dt_size, "-byte characters")
end
