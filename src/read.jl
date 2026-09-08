# The reading API. A caller states the type it expects, so every read has a concrete return
# type — `--trim=safe` rejects a call whose return type is only known from the file.

"""
    MatClass

The MATLAB class of a variable, as recorded in its `MATLAB_class` attribute. `MAT_UNSUPPORTED`
covers everything this package does not read yet, so a caller can walk a file and skip what it
cannot handle without an exception.
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

An open MATLAB v7.3 file together with its top-level variable names and their object-header
addresses. Construct one with [`matopen`](@ref).
"""
struct MatFile
    h5::H5File
    names::Vector{String}
    addrs::Vector{Int}
end

"""
    matopen(path) -> MatFile

Open a MATLAB v7.3 (HDF5-based) `.mat` file and read its top-level variable list.
"""
function matopen(path::String)
    h5 = open_h5(path)
    names, addrs = rootentries(h5)
    return MatFile(h5, names, addrs)
end

Base.keys(f::MatFile) = copy(f.names)

function lookup(f::MatFile, name::String)
    for i in eachindex(f.names)
        f.names[i] == name && return f.addrs[i]
    end
    return error("no variable named \"", name, "\" in this file")
end

"""
    matclass(f, name) -> MatClass

The MATLAB class of variable `name`. Returns `MAT_UNSUPPORTED` rather than throwing for a
class this package does not read, so a file can be surveyed before anything is read from it.
"""
function matclass(f::MatFile, name::String)
    oi = objinfo(f.h5, lookup(f, name))
    # A MATLAB object, or a sparse array, is not the plain class its attribute names.
    (iszero(oi.mobject) && oi.msparse < 0) || return MAT_UNSUPPORTED
    return classof(oi.mclass)
end

"""
    matsize(f, name) -> Vector{Int}

Size of variable `name` in MATLAB's own dimension order.

A `Vector` rather than a tuple: the rank is a property of the file, so a tuple would have a
length only known at run time and the return type would not be concrete.
"""
function matsize(f::MatFile, name::String)
    oi = objinfo(f.h5, lookup(f, name))
    return matsize(f.h5, oi)
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

Read variable `name`, which must hold an `N`-dimensional array of `T`. The on-disk datatype
is checked against `T` and a mismatch is an error rather than a reinterpretation.

`T` may be a real number type, `Bool` for a MATLAB logical array, or `Complex{T}` for a
complex one. Use the `String` method for char data.

MATLAB stores its dimensions reversed and its elements column-major, so filling a Julia array
in file order under the reversed dimensions reproduces the MATLAB array as written — no
transpose is involved.
"""
function matread(f::MatFile, name::String, ::Type{Array{T, N}}) where {T, N}
    oi = objinfo(f.h5, lookup(f, name))
    iszero(oi.mobject) || error("variable \"", name, "\" is a MATLAB object, which is not read")
    oi.msparse < 0 || error("variable \"", name, "\" is sparse, which is not read")

    oi.mempty && return emptyarray(Array{T, N}, matsize(f.h5, oi), name)

    oi.nd == N || error("variable \"", name, "\" has rank ", oi.nd, ", not ", N)
    checkdatatype(oi, T, name)

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
    matread(f, name, String) -> String

Read a MATLAB char row vector. MATLAB stores char data as UTF-16 code units, or as bytes for
a purely 7-bit string, and both are converted here.

Only a `1xN` char array is a string; a char matrix is several rows and has no single string
representation, so it is refused rather than flattened.
"""
function matread(f::MatFile, name::String, ::Type{String})
    oi = objinfo(f.h5, lookup(f, name))
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
