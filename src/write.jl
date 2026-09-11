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

# What one node of the file is. A group holds other nodes. A dataset holds bytes. A cell is a
# dataset whose bytes are the addresses of its children, which are known only once the whole
# file has been laid out.
const NODE_GROUP = 0
const NODE_DATASET = 1
const NODE_CELL = 2

"""
    MatNode

One object in the file. Children are positions in the writer's list, so a tree of them needs
no recursive type and no pointer chasing.

A value is reduced to bytes when it is added. Keeping user values instead would make the
writer hold a container of mixed type.
"""
struct MatNode
    name::String
    kind::Int
    datatype::Vector{UInt8}
    dataspace::Vector{UInt8}
    attributes::Vector{Vector{UInt8}}
    data::Vector{UInt8}
    children::Vector{Int}
end

groupnode(name::String, attrs::Vector{Vector{UInt8}}) =
    MatNode(name, NODE_GROUP, UInt8[], UInt8[], attrs, UInt8[], Int[])

function datasetnode(
        name::String, datatype::Vector{UInt8}, dataspace::Vector{UInt8},
        attrs::Vector{Vector{UInt8}}, data::Vector{UInt8},
    )
    return MatNode(name, NODE_DATASET, datatype, dataspace, attrs, data, Int[])
end

"""
    MatWriter()

Collect variables, then give the result to [`matwrite`](@ref).

Use this when you build a set of variables in a loop. Add each one with `push!`.

Nothing is written until the end. The place of each array in the file depends on the size of
every other array, so all sizes must be known first.
"""
struct MatWriter
    nodes::Vector{MatNode}
end

"The root group is always the first node, so its position is a constant."
const ROOT = 1

MatWriter() = MatWriter(MatNode[groupnode("", Vector{UInt8}[])])

"Add `node` under `parent` and give back its position."
function addnode!(w::MatWriter, parent::Int, node::MatNode)
    push!(w.nodes, node)
    i = length(w.nodes)
    push!(w.nodes[parent].children, i)
    return i
end

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

"""
Datatype message body for an object reference, which is how a cell array stores its items: 8
bytes holding the address of another object header.
"""
function reference_datatype_message()
    v = UInt8[0x17, 0x00, 0x00, 0x00]         # version 1, class 7; object reference
    putuint!(v, 8, 4)
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

"""
The messages of one node's object header.

No message's size depends on an address it carries, so calling this with zeros gives the
header's size before any address is settled.
"""
function node_messages(w::MatWriter, i::Int, hdrs::Vector{Int}, data_addr::Int, base::Int)
    n = w.nodes[i]
    messages = Tuple{Int, Vector{UInt8}}[]
    if n.kind == NODE_GROUP
        push!(messages, (2, link_info_message()))
        for c in n.children
            push!(messages, (6, link_message(w.nodes[c].name, hdrs[c] - base)))
        end
    else
        push!(messages, (1, n.dataspace))
        push!(messages, (3, n.datatype))
        push!(messages, (8, layout_message(data_addr, length(n.data))))
    end
    for a in n.attributes
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
Add one value under `parent`, and give back its position.

The methods cover the whole of what this package writes. Each one settles what to write from
the type it is given, so the choice is made while the program is compiled.
"""
function addvalue!(
        w::MatWriter, parent::Int, name::String, a::Array{T, N},
    ) where {T <: Union{Bool, Float32, Float64, Integer}, N}
    attrs = Vector{UInt8}[matlab_class_attribute(matlab_class(T))]
    T === Bool && push!(attrs, matlab_int_decode_attribute(1))
    dt = T === Bool ? datatype_message(UInt8) : datatype_message(T)
    return addnode!(
        w, parent,
        datasetnode(name, dt, dataspace_message(hdf5dims(a)), attrs, rawbytes(a)),
    )
end

# A MATLAB scalar is a 1x1 array, which is what MATLAB itself shows for one number.
function addvalue!(
        w::MatWriter, parent::Int, name::String, x::Union{Bool, Float32, Float64, Integer},
    )
    return addvalue!(w, parent, name, fill(x, 1, 1))
end

"MATLAB holds char data as UTF-16 code units in a 1xN array."
function addvalue!(w::MatWriter, parent::Int, name::String, s::AbstractString)
    units = transcode(UInt16, String(s))
    attrs = Vector{UInt8}[
        matlab_class_attribute("char"), matlab_int_decode_attribute(2),
    ]
    return addnode!(
        w, parent,
        datasetnode(
            name, datatype_message(UInt16), dataspace_message([length(units), 1]),
            attrs, collect(reinterpret(UInt8, units)),
        ),
    )
end

# ── structs and cells ───────────────────────────────────────────────────────

"""
Add the fields of a named tuple as the fields of a MATLAB struct.

The loop over the fields is written out when the program is compiled, so every field is added
by a call whose type is already settled.
"""
@generated function addfields!(w::MatWriter, parent::Int, nt::NT) where {NT <: NamedTuple}
    calls = Expr[]
    for name in fieldnames(NT)
        push!(calls, :(addvalue!(w, parent, $(String(name)), getfield(nt, $(QuoteNode(name))))))
    end
    return Expr(:block, calls..., :(return w))
end

"A named tuple becomes a MATLAB struct: a group with one member for each field."
function addvalue!(w::MatWriter, parent::Int, name::String, nt::NamedTuple)
    i = addnode!(w, parent, groupnode(name, Vector{UInt8}[matlab_class_attribute("struct")]))
    addfields!(w, i, nt)
    return i
end

"""
The group that holds the contents of every cell array.

A cell holds addresses. An object an address points at must still be linked somewhere, or the
file holds an object no reader can reach by name. MATLAB uses this name for the same purpose.
"""
function refsgroup!(w::MatWriter)
    for c in w.nodes[ROOT].children
        w.nodes[c].name == "#refs#" && return c
    end
    return addnode!(w, ROOT, groupnode("#refs#", Vector{UInt8}[]))
end

"""
Add the items of a tuple to `#refs#` and record where each one went.

The loop is written out when the program is compiled, so each item is added by a call whose
type is already settled. Nothing looks an item up by its name inside `#refs#`, so a running
count is enough to keep the names apart.
"""
@generated function additems!(w::MatWriter, cell::Int, refs::Int, t::T) where {T <: Tuple}
    calls = Expr[]
    for i in 1:fieldcount(T)
        push!(
            calls,
            :(
                push!(
                    w.nodes[cell].children,
                    addvalue!(w, refs, string(length(w.nodes)), getfield(t, $i)),
                )
            ),
        )
    end
    return Expr(:block, calls..., :(return w))
end

"""
A tuple becomes a MATLAB cell array of one row.

The items may have different types, which is what a cell array is for. Each one is written in
`#refs#`, and the cell itself holds the address of each.
"""
function addvalue!(w::MatWriter, parent::Int, name::String, t::Tuple)
    n = length(t)
    n > 0 || error("cannot write an empty cell array under \"", name, "\"")
    node = MatNode(
        name, NODE_CELL, reference_datatype_message(), dataspace_message([n, 1]),
        Vector{UInt8}[matlab_class_attribute("cell")], zeros(UInt8, 8n), Int[],
    )
    i = addnode!(w, parent, node)
    refs = refsgroup!(w)
    additems!(w, i, refs, t)
    return i
end

"""
    push!(w, name, value)

Add `value` under `name`.

| you give | MATLAB sees |
|---|---|
| an `Array` of numbers or `Bool` | an array of the matching type |
| one number or `Bool` | a 1x1 array |
| a `String` | text |
| a `NamedTuple` | a struct, one field per name |
| a `Tuple` | a cell array of one row |

A named tuple or a tuple may hold any of these in turn, so structs and cells nest.
"""
function Base.push!(w::MatWriter, name::String, value)
    addvalue!(w, ROOT, name, value)
    return w
end

"""
    matwrite(path, w::MatWriter)
    matwrite(path, pairs...)

Write a MATLAB `.mat` file of version 7.3.

```julia
matwrite("out.mat", "A" => A, "flags" => flags, "label" => "hello")

# A named tuple becomes a struct, and a tuple becomes a cell array. Both nest.
matwrite(
    "run.mat",
    "cfg" => (gain = 2.5, mode = "fast", limits = (1.0, 10.0)),
    "runs" => ([1.0 2.0], "second", (name = "third", ok = true)),
)
```

MATLAB reads the result. It is not compressed, so it is larger than a file MATLAB writes.
"""
function matwrite(path::String, w::MatWriter)
    isempty(w.nodes[ROOT].children) && error("nothing to write")

    # Lay the file out: user block, superblock, every object header, then every block of data.
    # A message's size never depends on the address it carries, so all the sizes are settled
    # first and the addresses second.
    sb_off = USERBLOCK
    sb_size = 48

    nnodes = length(w.nodes)
    zeros_ = zeros(Int, nnodes)
    header_sizes = Int[object_header_size(node_messages(w, i, zeros_, 0, 0)) for i in 1:nnodes]

    hdr_offs = Vector{Int}(undef, nnodes)
    data_offs = zeros(Int, nnodes)
    off = sb_off + sb_size
    for i in 1:nnodes
        hdr_offs[i] = off
        off += header_sizes[i]
    end
    for i in 1:nnodes
        w.nodes[i].kind == NODE_GROUP && continue
        data_offs[i] = off
        off += length(w.nodes[i].data)
    end
    eof = off

    # A cell holds the address of each of its items, so its own bytes can only be filled in
    # once every header has a place.
    for i in 1:nnodes
        w.nodes[i].kind == NODE_CELL || continue
        n = w.nodes[i]
        for (k, c) in enumerate(n.children)
            a = UInt64(hdr_offs[c] - sb_off)
            for b in 0:7
                n.data[8 * (k - 1) + b + 1] = unsafe_trunc(UInt8, a >> (8 * b))
            end
        end
    end

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
    putuint!(sb, hdr_offs[ROOT] - sb_off, 8)
    putuint!(sb, checksum(sb, 0, length(sb)), 4)
    length(sb) == sb_size || error("superblock is ", length(sb), " bytes, expected ", sb_size)
    append!(out, sb)

    for i in 1:nnodes
        hdr = object_header(node_messages(w, i, hdr_offs, data_offs[i] - sb_off, sb_off))
        length(hdr) == header_sizes[i] || error("an object header size was mispredicted")
        append!(out, hdr)
    end
    for i in 1:nnodes
        w.nodes[i].kind == NODE_GROUP && continue
        append!(out, w.nodes[i].data)
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
