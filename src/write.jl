# Writing MATLAB v7.3 files.
#
# The target is the shape libhdf5 produces, which is what MAT.jl and HDF5.jl write and what
# MATLAB reads back: a 512-byte user block holding the MATLAB banner, superblock version 2,
# version-2 object headers, a root group whose members are link messages, and contiguous
# uncompressed datasets. Choosing that over the old-style groups MATLAB itself writes avoids
# local heaps and version-1 B-trees entirely.

const MAT_BANNER = "MATLAB 7.3 MAT-file, Platform: Julia, Created by MAT73.jl"
const USERBLOCK = 512
const UNDEF_ADDR = typemax(UInt64)

@inline function putuint!(v::Vector{UInt8}, x::Integer, n::Int)
    u = UInt64(x)
    for i in 0:(n - 1)
        push!(v, unsafe_trunc(UInt8, u >> (8 * i)))
    end
    return v
end

"""
    MatEntry

One variable, already reduced to the bytes that describe it. Reducing at `push!` time keeps
each call concrete in the element type rather than storing user arrays of mixed type.
"""
struct MatEntry
    name::String
    datatype::Vector{UInt8}
    dataspace::Vector{UInt8}
    attributes::Vector{Vector{UInt8}}
    data::Vector{UInt8}
end

"""
    MatWriter()

Collect variables, then hand the result to [`matwrite`](@ref). Addresses cannot be assigned
until every variable's size is known, so nothing reaches the file before then.
"""
struct MatWriter
    entries::Vector{MatEntry}
end
MatWriter() = MatWriter(MatEntry[])

# ── message bodies ──────────────────────────────────────────────────────────

"Datatype message body. Byte 0 packs version in the high nibble and class in the low one."
function datatype_message(::Type{T}) where {T <: Union{Float32, Float64}}
    v = UInt8[]
    prec = 8 * sizeof(T)
    push!(v, 0x11)                            # version 1, class 1 (floating point)
    # Little-endian, mantissa normalised with an implied leading one, sign at the top bit.
    push!(v, 0x20, UInt8(prec - 1), 0x00)
    putuint!(v, sizeof(T), 4)
    putuint!(v, 0, 2)                         # bit offset
    putuint!(v, prec, 2)                      # bit precision
    if T === Float64
        push!(v, 52, 11, 0, 52)               # exponent at 52 (11 bits), mantissa 52 bits
        putuint!(v, 1023, 4)
    else
        push!(v, 23, 8, 0, 23)
        putuint!(v, 127, 4)
    end
    return v
end

function datatype_message(::Type{T}) where {T <: Integer}
    v = UInt8[]
    push!(v, 0x10)                            # version 1, class 0 (fixed point)
    push!(v, T <: Signed ? 0x08 : 0x00, 0x00, 0x00)   # little-endian, signed flag in bit 3
    putuint!(v, sizeof(T), 4)
    putuint!(v, 0, 2)
    putuint!(v, 8 * sizeof(T), 2)
    return v
end

"A fixed-length, NUL-terminated ASCII string, which is how the MATLAB_* attributes are typed."
function string_datatype_message(n::Int)
    v = UInt8[]
    push!(v, 0x13, 0x00, 0x00, 0x00)          # version 1, class 3; NUL-terminated, ASCII
    putuint!(v, n, 4)
    return v
end

"Dataspace message body, version 2. `dims` is in HDF5 order, slowest varying first."
function dataspace_message(dims::Vector{Int})
    v = UInt8[]
    push!(v, 0x02, UInt8(length(dims)), 0x00, isempty(dims) ? 0x00 : 0x01)
    for d in dims
        putuint!(v, d, 8)
    end
    return v
end

scalar_dataspace_message() = UInt8[0x02, 0x00, 0x00, 0x00]

"Data layout message body, version 3, contiguous storage."
function layout_message(addr::Int, nbytes::Int)
    v = UInt8[]
    push!(v, 0x03, 0x01)
    putuint!(v, addr, 8)
    putuint!(v, nbytes, 8)
    return v
end

"Attribute message body, version 2, which pads none of its parts."
function attribute_message(name::String, datatype::Vector{UInt8}, dataspace::Vector{UInt8}, data::Vector{UInt8})
    v = UInt8[]
    namebytes = codeunits(name)
    push!(v, 0x02, 0x00)
    putuint!(v, length(namebytes) + 1, 2)     # the NUL is counted
    putuint!(v, length(datatype), 2)
    putuint!(v, length(dataspace), 2)
    append!(v, namebytes)
    push!(v, 0x00)
    append!(v, datatype)
    append!(v, dataspace)
    append!(v, data)
    return v
end

function matlab_class_attribute(class::String)
    return attribute_message(
        "MATLAB_class", string_datatype_message(length(class)),
        scalar_dataspace_message(), collect(codeunits(class)),
    )
end

function matlab_int_decode_attribute(kind::Int)
    data = UInt8[]
    putuint!(data, kind, 4)
    return attribute_message(
        "MATLAB_int_decode", datatype_message(Int32), scalar_dataspace_message(), data,
    )
end

"Link message body. Only hard links are written, so no link-type byte is needed."
function link_message(name::String, addr::Int)
    v = UInt8[]
    namebytes = codeunits(name)
    n = length(namebytes)
    lensize = n <= 0xff ? 1 : (n <= 0xffff ? 2 : 4)
    flags = lensize == 1 ? 0x00 : (lensize == 2 ? 0x01 : 0x02)
    push!(v, 0x01, flags)
    putuint!(v, n, lensize)
    append!(v, namebytes)
    putuint!(v, addr, 8)
    return v
end

"Link info message body: both indexes undefined, so the group's links are stored compactly."
function link_info_message()
    v = UInt8[0x00, 0x00]
    putuint!(v, UNDEF_ADDR, 8)
    putuint!(v, UNDEF_ADDR, 8)
    return v
end

# ── object headers ──────────────────────────────────────────────────────────

"Bytes a version-2 object header message occupies, including its four-byte prologue."
message_size(body::Vector{UInt8}) = 4 + length(body)

"""
Serialise a version-2 object header holding `messages`, each a `(type, body)` pair. The
checksum covers the header from its signature through the last message.
"""
function object_header(messages::Vector{Tuple{Int, Vector{UInt8}}})
    chunk = sum(message_size(m[2]) for m in messages; init = 0)
    v = UInt8[]
    append!(v, codeunits("OHDR"))
    push!(v, 0x02, 0x02)                      # version 2, with a 4-byte message-block size
    putuint!(v, chunk, 4)
    for (mtype, body) in messages
        push!(v, UInt8(mtype))
        putuint!(v, length(body), 2)
        push!(v, 0x00)                        # message flags
        append!(v, body)
    end
    putuint!(v, checksum(v, 0, length(v)), 4)
    return v
end

"Size of the header `object_header` would produce, without building it."
function object_header_size(messages::Vector{Tuple{Int, Vector{UInt8}}})
    # Signature, version, flags and the message-block size come to ten bytes, and a
    # four-byte checksum closes the header.
    return 14 + sum(message_size(m[2]) for m in messages; init = 0)
end

function dataset_messages(e::MatEntry, data_addr::Int)
    messages = Tuple{Int, Vector{UInt8}}[]
    push!(messages, (1, e.dataspace))
    push!(messages, (3, e.datatype))
    push!(messages, (8, layout_message(data_addr, length(e.data))))
    for a in e.attributes
        push!(messages, (12, a))
    end
    return messages
end

# ── the public interface ────────────────────────────────────────────────────

"HDF5 stores dimensions in the reverse of MATLAB's order."
hdf5dims(a::AbstractArray) = collect(reverse(size(a)))

rawbytes(a::Array{T}) where {T} = collect(reinterpret(UInt8, vec(a)))
# Julia's Bool is already a byte holding 0 or 1, which is MATLAB's logical representation.
rawbytes(a::Array{Bool}) = collect(reinterpret(UInt8, vec(a)))

matlab_class(::Type{Float64}) = "double"
matlab_class(::Type{Float32}) = "single"
matlab_class(::Type{Bool}) = "logical"
matlab_class(::Type{T}) where {T <: Integer} = lowercase(string(nameof(T)))

"""
    push!(w, name, a)

Add array `a` under `name`. The array is converted to bytes immediately, so `w` never holds
values of mixed type.
"""
function Base.push!(w::MatWriter, name::String, a::Array{T, N}) where {T <: Union{Bool, Float32, Float64, Integer}, N}
    attrs = Vector{UInt8}[matlab_class_attribute(matlab_class(T))]
    T === Bool && push!(attrs, matlab_int_decode_attribute(1))
    dt = T === Bool ? datatype_message(UInt8) : datatype_message(T)
    push!(
        w.entries,
        MatEntry(name, dt, dataspace_message(hdf5dims(a)), attrs, rawbytes(a)),
    )
    return w
end

"""
    push!(w, name, s)

Add a string under `name`. MATLAB holds char data as UTF-16 code units in a `1xN` array.
"""
function Base.push!(w::MatWriter, name::String, s::AbstractString)
    units = transcode(UInt16, String(s))
    attrs = Vector{UInt8}[
        matlab_class_attribute("char"), matlab_int_decode_attribute(2),
    ]
    push!(
        w.entries,
        MatEntry(
            name, datatype_message(UInt16), dataspace_message([length(units), 1]),
            attrs, collect(reinterpret(UInt8, units)),
        ),
    )
    return w
end

"""
    matwrite(path, w::MatWriter)
    matwrite(path, pairs...)

Write a MATLAB v7.3 file. Every address is assigned before anything is serialised, because a
dataset's header records where its data lives.
"""
function matwrite(path::String, w::MatWriter)
    isempty(w.entries) && error("nothing to write")

    # Lay the file out: user block, superblock, root group, dataset headers, then the data.
    # A message's size never depends on the address it carries, so sizes are known first.
    sb_off = USERBLOCK
    sb_size = 48
    root_off = sb_off + sb_size

    linkmsgs = Tuple{Int, Vector{UInt8}}[(2, link_info_message())]
    header_sizes = Int[]
    for e in w.entries
        push!(header_sizes, object_header_size(dataset_messages(e, 0)))
    end
    root_size = 0
    hdr_offs = Int[]
    let off = 0
        # The link messages need the header addresses, which need the root group's size,
        # which needs the link messages: resolved by noting that a link message's size is
        # independent of the address inside it.
        probe = Tuple{Int, Vector{UInt8}}[(2, link_info_message())]
        for e in w.entries
            push!(probe, (6, link_message(e.name, 0)))
        end
        root_size = object_header_size(probe)
        off = root_off + root_size
        for s in header_sizes
            push!(hdr_offs, off)
            off += s
        end
        data_off = off
        for (i, e) in enumerate(w.entries)
            push!(linkmsgs, (6, link_message(e.name, hdr_offs[i] - sb_off)))
            push!(hdr_offs, data_off)   # data addresses are appended after the headers
            data_off += length(e.data)
        end
    end

    n = length(w.entries)
    data_offs = hdr_offs[(n + 1):end]
    hdr_offs = hdr_offs[1:n]
    eof = data_offs[end] + length(w.entries[end].data)

    out = Vector{UInt8}(undef, 0)
    sizehint!(out, eof)
    append!(out, codeunits(MAT_BANNER))
    while length(out) < USERBLOCK
        push!(out, 0x00)
    end

    # Superblock version 2. Addresses stored in the file are relative to the base address,
    # which is the superblock's own position; the end-of-file address is absolute.
    sb = UInt8[0x89]
    append!(sb, codeunits("HDF"))
    push!(sb, 0x0d, 0x0a, 0x1a, 0x0a)
    push!(sb, 0x02, 0x08, 0x08, 0x00)         # version 2, 8-byte offsets and lengths
    putuint!(sb, sb_off, 8)                   # base address
    putuint!(sb, UNDEF_ADDR, 8)               # superblock extension
    putuint!(sb, eof, 8)
    putuint!(sb, root_off - sb_off, 8)
    putuint!(sb, checksum(sb, 0, length(sb)), 4)
    length(sb) == sb_size || error("superblock is ", length(sb), " bytes, expected ", sb_size)
    append!(out, sb)

    root = object_header(linkmsgs)
    length(root) == root_size || error("root group header size was mispredicted")
    append!(out, root)

    for (i, e) in enumerate(w.entries)
        hdr = object_header(dataset_messages(e, data_offs[i] - sb_off))
        length(hdr) == header_sizes[i] || error("dataset header size was mispredicted")
        append!(out, hdr)
    end
    for e in w.entries
        append!(out, e.data)
    end
    length(out) == eof || error("wrote ", length(out), " bytes, expected ", eof)

    # Not the `open(f, path, mode) do` form: it splats its arguments through
    # `Core._apply_iterate`, which is not statically resolvable.
    io = open(path, "w")
    try
        write(io, out)
    finally
        close(io)
    end
    return path
end

function matwrite(path::String, pairs::Pair...)
    w = MatWriter()
    for (name, value) in pairs
        push!(w, String(name), value)
    end
    return matwrite(path, w)
end
