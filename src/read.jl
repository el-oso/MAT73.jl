# The reading API. A caller states the type it expects, so every read has a concrete return
# type — `--trim=safe` rejects a call whose return type is only known from the file.

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
    error("no variable named \"", name, "\" in this file")
end

"""
    matsize(f, name) -> Dims

Size of variable `name` in MATLAB's own dimension order.
"""
function matsize(f::MatFile, name::String)
    oi = objinfo(f.h5, lookup(f, name))
    return ntuple(k -> matdim(oi.dims, k, oi.nd), oi.nd)
end

# What an on-disk datatype must look like to be read as `T`. Both the class and the width
# are checked: a size-only check reads past the dataset extent and returns garbage.
@inline dtclass(::Type{<:AbstractFloat}) = DT_FLOAT
@inline dtclass(::Type{<:Integer}) = DT_FIXED

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

"""
    matread(f, name, Array{T,N}) -> Array{T,N}

Read variable `name`, which must hold an `N`-dimensional array of `T`. The on-disk datatype
is checked against `T` and a mismatch is an error rather than a reinterpretation.

MATLAB stores its dimensions reversed and its elements column-major, so filling a Julia
array in file order under the reversed dimensions reproduces the MATLAB array as written —
no transpose is involved.
"""
function matread(f::MatFile, name::String, ::Type{Array{T, N}}) where {T, N}
    oi = objinfo(f.h5, lookup(f, name))
    oi.nd == N || error("variable \"", name, "\" has rank ", oi.nd, ", not ", N)
    checkdatatype(oi, T, name)
    oi.layout == LAYOUT_CHUNKED &&
        error("variable \"", name, "\" is chunked; only contiguous and compact layouts are read")
    (oi.layout == LAYOUT_COMPACT || oi.layout == LAYOUT_CONTIGUOUS) ||
        error("variable \"", name, "\" has no readable data layout")
    oi.data_off >= 0 || error("variable \"", name, "\" has no allocated storage")

    n = 1
    for k in 1:oi.nd
        n *= oi.dims[k]
    end
    sz = sizeof(T)
    oi.data_size >= n * sz || error("stored extent is shorter than the dataspace")
    oi.data_off + n * sz <= length(f.h5.buf) || error("data extends past the end of the file")

    dims = ntuple(k -> matdim(oi.dims, k, oi.nd), Val(N))
    out = Array{T, N}(undef, dims)
    b = f.h5.buf
    off = oi.data_off
    for i in eachindex(out)
        out[i] = fromuint(T, readuint(b, off + (i - 1) * sz, sz))
    end
    return out
end
