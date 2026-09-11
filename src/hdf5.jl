# The subset of HDF5 that MATLAB's v7.3 writer emits, plus the subset this package's own
# writer emits.
#
# MATLAB writes superblock version 0, version-1 object headers and old-style groups (a local
# heap of names indexed by a version-1 B-tree). HDF5.jl, MAT.jl and `matwrite` here write
# superblock version 2, version-2 object headers and compact groups made of link messages.
# Both are read.
#
# Everything is written to stay statically resolvable under `juliac --trim=safe`: concrete
# field types, no closures over loop-mutated locals, no runtime-constructed types.

const H5SIG = (0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a)
const OHDR_SIG = (0x4f, 0x48, 0x44, 0x52)   # "OHDR", a version-2 object header
const OCHK_SIG = (0x4f, 0x43, 0x48, 0x4b)   # "OCHK", its continuation block

"Highest dataspace rank this reader accepts. MATLAB arrays are far below it."
const MAXRANK = 8

# Addresses are carried as `Int`; -1 means absent or undefined.
struct H5File
    buf::Vector{UInt8}
    sb::Int        # 0-based file offset of the superblock signature
    osize::Int     # size of offsets, in bytes
    lsize::Int     # size of lengths, in bytes
    baseaddr::Int  # every address stored in the file is relative to this
    root::Int      # root group object header address
end

# Layout class of a dataset's raw data, as HDF5 numbers them.
const LAYOUT_NONE = -1
const LAYOUT_COMPACT = 0
const LAYOUT_CONTIGUOUS = 1
const LAYOUT_CHUNKED = 2

# Datatype class, as HDF5 numbers them.
const DT_FIXED = 0
const DT_FLOAT = 1
const DT_STRING = 3
const DT_COMPOUND = 6
const DT_REFERENCE = 7

# Filter identifiers, as HDF5 registers them.
const FILTER_DEFLATE = 1
const FILTER_SHUFFLE = 2

"Most filters a pipeline may hold here. MATLAB writes at most shuffle followed by deflate."
const MAXFILTERS = 4

"A group entry: a name and the address of the object header it points at."
const Link = Tuple{String, Int}

"""
    MatRef

A mark that points to another item in the same file.

Think of a numbered ticket from a cloakroom. The ticket is not the coat. You hand it back to
get the coat.

A MATLAB cell array holds one mark for each item. So does each field of a struct array. The
items can have different types, so no single type covers them all.

Give a mark to [`matread`](@ref), [`matclass`](@ref) or [`matsize`](@ref), in the place where
you would give a variable name. You then state the type of that one item.
"""
struct MatRef
    addr::Int
end

# The object-header fields a read needs. A fixed layout keeps inference concrete.
#
# The filter pipeline is a fixed-size tuple rather than a vector of filter objects: a
# container whose length or element type comes from the file cannot be dispatched on
# statically, which is precisely what `--trim=safe` rejects.
struct ObjInfo
    stab_btree::Int
    stab_heap::Int
    links::Vector{Link}  # from link messages; a compact group carries its entries here
    # A link-info message marks a group whether or not it holds any links, which is the only
    # thing that says an empty compact group is a group.
    linkinfo::Bool
    layout::Int
    data_off::Int    # 0-based file offset of the raw data, -1 if unallocated
    data_size::Int   # bytes
    nd::Int
    dims::NTuple{MAXRANK, Int}
    dt_class::Int
    dt_size::Int     # bytes per element
    dt_signed::Bool  # meaningful only for DT_FIXED
    dt_bigendian::Bool
    # The two halves of a complex number, which a compound datatype describes. 0 when the
    # datatype is not compound, or when its members were not read.
    dt_member_class::Int
    dt_member_size::Int
    # Chunked storage. `chunk_ndl` counts the dimensions as stored, which is the dataspace
    # rank plus one: HDF5 appends the element size as a trailing chunk dimension.
    chunk_btree::Int
    chunk_ndl::Int
    chunk_dims::NTuple{MAXRANK + 1, Int}
    nfilters::Int
    filter_ids::NTuple{MAXFILTERS, Int}
    filter_cd1::NTuple{MAXFILTERS, Int}  # first client value; shuffle's is its element size
    # The MATLAB_* attributes. They carry everything HDF5 itself does not say: which MATLAB
    # class the bytes represent, and whether the dataset stands in for an empty array.
    mclass::String       # "" when absent, so this is not a MATLAB-written dataset
    int_decode::Int      # 1 logical, 2 char; 0 when absent
    mempty::Bool         # the data holds the array's dimensions, not its elements
    msparse::Int         # row count of a sparse array, -1 when absent
    mobject::Int         # 1 function handle, 2 old-style object, 3 opaque; 0 when absent
end

# Mutable twin of ObjInfo, filled while scanning messages. Both object header versions share
# `handle_message!`, so the two differ only in how they frame their messages.
mutable struct ObjAcc
    stab_btree::Int
    stab_heap::Int
    links::Vector{Link}
    linkinfo::Bool
    layout::Int
    data_off::Int
    data_size::Int
    nd::Int
    dims::NTuple{MAXRANK, Int}
    dt_class::Int
    dt_size::Int
    dt_signed::Bool
    dt_bigendian::Bool
    dt_member_class::Int
    dt_member_size::Int
    chunk_btree::Int
    chunk_ndl::Int
    chunk_dims::NTuple{MAXRANK + 1, Int}
    nfilters::Int
    filter_ids::NTuple{MAXFILTERS, Int}
    filter_cd1::NTuple{MAXFILTERS, Int}
    mclass::String
    int_decode::Int
    mempty::Bool
    msparse::Int
    mobject::Int
    blocks::Vector{Int}   # (start, length) pairs of message blocks still to scan
end

ObjAcc() = ObjAcc(
    -1, -1, Link[], false, LAYOUT_NONE, -1, 0, 0, (0, 0, 0, 0, 0, 0, 0, 0),
    -1, 0, false, false, 0, 0, -1, 0, (0, 0, 0, 0, 0, 0, 0, 0, 0),
    0, (0, 0, 0, 0), (0, 0, 0, 0), "", 0, false, -1, 0, Int[],
)

function ObjInfo(a::ObjAcc)
    # A contiguous extent comes from dataspace times datatype: the layout message's stored
    # size counts elements in versions 1 and 2 but bytes in version 3.
    data_size = a.data_size
    if a.layout == LAYOUT_CONTIGUOUS
        n = 1
        for k in 1:a.nd
            n *= a.dims[k]
        end
        data_size = n * a.dt_size
    end
    return ObjInfo(
        a.stab_btree, a.stab_heap, a.links, a.linkinfo, a.layout, a.data_off, data_size,
        a.nd, a.dims,
        a.dt_class, a.dt_size, a.dt_signed, a.dt_bigendian,
        a.dt_member_class, a.dt_member_size,
        a.chunk_btree, a.chunk_ndl, a.chunk_dims, a.nfilters, a.filter_ids, a.filter_cd1,
        a.mclass, a.int_decode, a.mempty, a.msparse, a.mobject,
    )
end

@inline function readuint(buf::Vector{UInt8}, off::Int, n::Int)::UInt64
    v = UInt64(0)
    for i in 0:(n - 1)
        v |= UInt64(buf[off + i + 1]) << (8 * i)
    end
    return v
end

# All-ones is HDF5's undefined address.
@inline function readaddr(buf::Vector{UInt8}, off::Int, n::Int)::Int
    v = readuint(buf, off, n)
    mask = n >= 8 ? typemax(UInt64) : (UInt64(1) << (8 * n)) - UInt64(1)
    return v == mask ? -1 : Int(v)
end

@inline function sigat(buf::Vector{UInt8}, off::Int, sig::NTuple{4, UInt8})
    off + 4 <= length(buf) || return false
    for i in 1:4
        buf[off + i] == sig[i] || return false
    end
    return true
end

function open_h5(path::String)
    io = open(path, "r")
    buf = Mmap.mmap(io, Vector{UInt8})
    close(io)
    # The signature sits at a power-of-two multiple of 512. MATLAB uses 512: a user block
    # holding the "MATLAB 7.3 MAT-file" banner precedes the superblock.
    sb = -1
    probe = 0
    while probe + 8 <= length(buf)
        ok = true
        for i in 1:8
            if buf[probe + i] != H5SIG[i]
                ok = false
                break
            end
        end
        if ok
            sb = probe
            break
        end
        probe = iszero(probe) ? 512 : probe * 2
    end
    sb < 0 && error("no HDF5 superblock signature found")

    version = Int(buf[sb + 9])
    if iszero(version)
        osize = Int(buf[sb + 14])
        lsize = Int(buf[sb + 15])
        p = sb + 24                   # past prefix, K values and consistency flags
        baseaddr = Int(readuint(buf, p, osize))
        # base, free-space, end-of-file and driver-info addresses, then the root symbol
        # table entry, whose object header address follows its link-name offset.
        root = readaddr(buf, p + 4 * osize + osize, osize)
        return H5File(buf, sb, osize, lsize, baseaddr, root)
    elseif version == 2 || version == 3
        osize = Int(buf[sb + 10])
        lsize = Int(buf[sb + 11])
        p = sb + 12                   # past signature, version, sizes and consistency flags
        checkblock(buf, sb, p + 4 * osize, "the superblock")
        baseaddr = Int(readuint(buf, p, osize))
        # base address, superblock extension, end of file, then the root object header.
        root = readaddr(buf, p + 3 * osize, osize)
        # libhdf5 works from where the superblock actually is. A stored base that says
        # otherwise means the file has been moved or cut, and every address would be wrong.
        baseaddr == sb || error(
            "the superblock sits at ", sb, " but the file says its base address is ", baseaddr,
        )
        return H5File(buf, sb, osize, lsize, baseaddr, root)
    end
    return error("unsupported superblock version ", version)
end

@inline foff(f::H5File, addr::Int) = f.baseaddr + addr

"Set element `i` of a 4-tuple. An explicit ladder keeps the result's type a literal."
@inline function settuple4(t::NTuple{4, Int}, i::Int, v::Int)
    i == 1 && return (v, t[2], t[3], t[4])
    i == 2 && return (t[1], v, t[3], t[4])
    i == 3 && return (t[1], t[2], v, t[4])
    return (t[1], t[2], t[3], v)
end

"Chunk dimension `k`; they are 4 bytes each, unlike dataspace dimensions."
@inline function cdimat(buf::Vector{UInt8}, q::Int, k::Int, ndl::Int)::Int
    return k <= ndl ? Int(readuint(buf, q + (k - 1) * 4, 4)) : 0
end

# Top-level rather than closures: a closure capturing a loop-mutated local boxes it, which
# makes the enclosing frame unresolvable under `--trim=safe`.
@inline function dimat(buf::Vector{UInt8}, d::Int, k::Int, nd::Int, ls::Int)::Int
    return k <= nd ? Int(readuint(buf, d + (k - 1) * ls, ls)) : 0
end

"MATLAB dimension `k`, recovered from the reversed dimensions HDF5 stores."
@inline function matdim(dims::NTuple{MAXRANK, Int}, k::Int, nd::Int)::Int
    return k <= nd ? dims[nd - k + 1] : 1
end

"Bytes `[off+1, off+n]` as a string, without the trailing NULs a fixed-length string pads with."
function cstring(buf::Vector{UInt8}, off::Int, n::Int)
    e = off + n
    while e > off && iszero(buf[e])
        e -= 1
    end
    return String(buf[(off + 1):e])
end

"""
Locate the parts of an attribute message: its name, and the class, element size and file
offset of its data. Version 1 pads the name, datatype and dataspace blocks out to a multiple
of 8 bytes; versions 2 and 3 pad nothing, and version 3 inserts a character-set byte.
"""
function attrinfo(buf::Vector{UInt8}, d::Int)
    av = Int(buf[d + 1])
    namesize = Int(readuint(buf, d + 2, 2))
    dtsize = Int(readuint(buf, d + 4, 2))
    dssize = Int(readuint(buf, d + 6, 2))
    p = d + 8
    av == 3 && (p += 1)
    name = cstring(buf, p, namesize)
    if av == 1
        p += 8 * cld(namesize, 8)
        dtoff = p
        p += 8 * cld(dtsize, 8)
        p += 8 * cld(dssize, 8)
    else
        p += namesize
        dtoff = p
        p += dtsize
        p += dssize
    end
    acls = Int(buf[dtoff + 1] & 0x0f)
    asize = Int(readuint(buf, dtoff + 4, 4))
    return name, acls, asize, p
end

"""
Read one link message, which is how a compact group names its members. Only hard links are
followed; a soft or external link points outside this file's object headers.
"""
function readlink(f::H5File, d::Int)
    buf = f.buf
    p = d + 1                         # past the version byte
    flags = buf[d + 2]
    p += 1
    linktype = 0
    if !iszero(flags & 0x08)
        linktype = Int(buf[p + 1])
        p += 1
    end
    !iszero(flags & 0x04) && (p += 8)             # creation order
    !iszero(flags & 0x10) && (p += 1)             # name character set
    lensize = 1 << (flags & 0x03)
    namelen = Int(readuint(buf, p, lensize))
    p += lensize
    name = String(buf[(p + 1):(p + namelen)])
    p += namelen
    iszero(linktype) || return ("", -1)           # soft and external links are skipped
    return (name, readaddr(buf, p, f.osize))
end

"Decode one object-header message into `a`. Shared by both object header versions."
function handle_message!(a::ObjAcc, f::H5File, mtype::Int, d::Int)
    buf = f.buf
    if mtype == 1                        # dataspace
        v = Int(buf[d + 1])
        (v == 1 || v == 2) || error("unsupported dataspace version ", v)
        a.nd = Int(buf[d + 2])
        a.nd <= MAXRANK || error("dataspace rank above $MAXRANK is not supported")
        # Version 1 has one reserved byte and four more after the flags; version 2 replaces
        # all five with a single type byte, so the dimension list starts four bytes earlier.
        q = d + (v == 1 ? 8 : 4)
        ls = f.lsize
        a.dims = (
            dimat(buf, q, 1, a.nd, ls), dimat(buf, q, 2, a.nd, ls),
            dimat(buf, q, 3, a.nd, ls), dimat(buf, q, 4, a.nd, ls),
            dimat(buf, q, 5, a.nd, ls), dimat(buf, q, 6, a.nd, ls),
            dimat(buf, q, 7, a.nd, ls), dimat(buf, q, 8, a.nd, ls),
        )
    elseif mtype == 3                    # datatype
        # Byte 0 packs version in the high nibble and class in the low nibble.
        a.dt_class = Int(buf[d + 1] & 0x0f)
        a.dt_signed = !iszero((buf[d + 2] >> 3) & 0x01)
        a.dt_size = Int(readuint(buf, d + 4, 4))
        # Bit 0 of the class bit field is the byte order of a number.
        a.dt_bigendian = !iszero(buf[d + 2] & 0x01)
        if a.dt_class == DT_COMPOUND && isone(buf[d + 1] >> 4)
            # A complex number is a compound of 2 members. The first one says what the halves
            # are, which is the only thing that separates a complex double from a pair of
            # 8-byte integers. A version 1 member is a name padded to 8 bytes, then 32 bytes
            # of shape, then the member's own datatype message.
            n = 0
            while d + 9 + n <= length(buf) && !iszero(buf[d + 9 + n])
                n += 1
            end
            m = d + 8 + 8 * div(n + 8, 8) + 32
            if m + 8 <= length(buf)
                a.dt_member_class = Int(buf[m + 1] & 0x0f)
                a.dt_member_size = Int(readuint(buf, m + 4, 4))
                a.dt_bigendian = !iszero(buf[m + 2] & 0x01)
            end
        end
    elseif mtype == 2                    # link info
        a.linkinfo = true
    elseif mtype == 6                    # link
        name, addr = readlink(f, d)
        addr >= 0 && push!(a.links, (name, addr))
    elseif mtype == 8                    # data layout
        v = Int(buf[d + 1])
        if v == 3 || v == 4
            a.layout = Int(buf[d + 2])
            if a.layout == LAYOUT_COMPACT
                a.data_size = Int(readuint(buf, d + 2, 2))
                a.data_off = d + 4
            elseif a.layout == LAYOUT_CONTIGUOUS
                addr = readaddr(buf, d + 2, f.osize)
                a.data_off = addr < 0 ? -1 : foff(f, addr)
            elseif a.layout == LAYOUT_CHUNKED
                # Version 4 lays chunked storage out differently: flags, then a width for
                # the dimensions, then an indexing type. Only versions 1 to 3 are read.
                v == 3 || error("data layout version ", v, " chunked storage is not read")
                # Dimensionality, then the B-tree root, then that many 4-byte chunk
                # dimensions. The trailing one is the element size, not an extent.
                a.chunk_ndl = Int(buf[d + 3])
                a.chunk_ndl <= MAXRANK + 1 ||
                    error("chunk dimensionality above $(MAXRANK + 1) is not supported")
                a.chunk_btree = readaddr(buf, d + 3, f.osize)
                q = d + 3 + f.osize
                a.chunk_dims = (
                    cdimat(buf, q, 1, a.chunk_ndl), cdimat(buf, q, 2, a.chunk_ndl),
                    cdimat(buf, q, 3, a.chunk_ndl), cdimat(buf, q, 4, a.chunk_ndl),
                    cdimat(buf, q, 5, a.chunk_ndl), cdimat(buf, q, 6, a.chunk_ndl),
                    cdimat(buf, q, 7, a.chunk_ndl), cdimat(buf, q, 8, a.chunk_ndl),
                    cdimat(buf, q, 9, a.chunk_ndl),
                )
            end
        elseif v == 1 || v == 2
            ndl = Int(buf[d + 2])
            a.layout = Int(buf[d + 3])
            q = d + 8
            if a.layout != LAYOUT_COMPACT
                addr = readaddr(buf, q, f.osize)
                a.data_off = addr < 0 ? -1 : foff(f, addr)
                q += f.osize
            end
            q += ndl * 4                 # dimension sizes, in elements
            if a.layout == LAYOUT_COMPACT
                a.data_size = Int(readuint(buf, q, 4))
                a.data_off = q + 4
            end
        else
            error("unsupported data layout version ", v)
        end
    elseif mtype == 11                   # filter pipeline
        fv = Int(buf[d + 1])
        a.nfilters = Int(buf[d + 2])
        a.nfilters <= MAXFILTERS || error("more than $MAXFILTERS filters is not supported")
        # Version 1 pads the reserved header and every name and client-data block out to a
        # multiple of 8 bytes; version 2 pads nothing.
        q = fv == 1 ? d + 8 : d + 2
        ids = (0, 0, 0, 0)
        cd1 = (0, 0, 0, 0)
        for i in 1:(a.nfilters)
            fid = Int(readuint(buf, q, 2))
            # Version 2 omits the name-length field for the registered filters.
            named = fv == 1 || fid >= 256
            hdrlen = named ? 8 : 6
            namelen = named ? Int(readuint(buf, q + 2, 2)) : 0
            nclient = Int(readuint(buf, q + hdrlen - 2, 2))
            r = q + hdrlen + (fv == 1 ? 8 * cld(namelen, 8) : namelen)
            ids = settuple4(ids, i, fid)
            cd1 = settuple4(cd1, i, nclient >= 1 ? Int(readuint(buf, r, 4)) : 0)
            r += 4 * nclient
            fv == 1 && !iseven(nclient) && (r += 4)   # pad the block to 8 bytes
            q = r
        end
        a.filter_ids = ids
        a.filter_cd1 = cd1
    elseif mtype == 12                   # attribute
        aname, acls, asize, adata = attrinfo(buf, d)
        if aname == "MATLAB_class"
            a.mclass = cstring(buf, adata, asize)
        elseif aname == "MATLAB_int_decode"
            a.int_decode = Int(readuint(buf, adata, asize))
        elseif aname == "MATLAB_empty"
            a.mempty = !iszero(readuint(buf, adata, asize))
        elseif aname == "MATLAB_sparse"
            a.msparse = Int(readuint(buf, adata, asize))
        elseif aname == "MATLAB_object_decode"
            a.mobject = Int(readuint(buf, adata, asize))
        end
    elseif mtype == 16                   # object header continuation
        addr = readaddr(buf, d, f.osize)
        len = Int(readuint(buf, d + f.osize, f.lsize))
        if addr >= 0
            push!(a.blocks, foff(f, addr))
            push!(a.blocks, len)
        end
    elseif mtype == 17                   # symbol table
        a.stab_btree = readaddr(buf, d, f.osize)
        a.stab_heap = readaddr(buf, d + f.osize, f.osize)
    end
    return nothing
end

"Version-1 object header: a fixed 12-byte prefix, then messages on 8-byte boundaries."
function scan_v1!(a::ObjAcc, f::H5File, o::Int)
    buf = f.buf
    nmsg = Int(readuint(buf, o + 2, 2))
    push!(a.blocks, o + 16)
    push!(a.blocks, Int(readuint(buf, o + 8, 4)))
    seen = 0
    bi = 1
    while bi <= length(a.blocks) && seen < nmsg
        p = a.blocks[bi]
        stop = p + a.blocks[bi + 1]
        bi += 2
        while p + 8 <= stop && seen < nmsg
            mtype = Int(readuint(buf, p, 2))
            msize = Int(readuint(buf, p + 2, 2))
            d = p + 8
            seen += 1
            # Bit 1 of the flags says the body is a pointer to a message held elsewhere, not
            # the message. Reading it as the message would decode the pointer as data.
            iszero(buf[p + 5] & 0x02) ||
                error("this file shares an object header message, which is not read")
            handle_message!(a, f, mtype, d)
            p = d + msize
        end
    end
    return nothing
end

"""
Check the running total that closes a version-2 block.

Every version-2 structure ends with a checksum over its own bytes. Checking it turns a
damaged file into an error here rather than into values that look real.
"""
function checkblock(buf::Vector{UInt8}, start::Int, stop::Int, what::String)
    (start >= 0 && stop >= start && stop + 4 <= length(buf)) ||
        error(what, " runs past the end of the file")
    want = readuint(buf, stop, 4)
    got = checksum(buf, start, stop - start)
    got == want || error(what, " is damaged: its running total does not match its bytes")
    return nothing
end

"""
Version-2 object header: a signed block whose size is declared up front, holding messages
with a one-byte type and a flags byte. Continuation blocks repeat the shape behind an "OCHK"
signature, and each block ends with a checksum over the block.
"""
function scan_v2!(a::ObjAcc, f::H5File, o::Int)
    buf = f.buf
    flags = buf[o + 6]
    p = o + 6                         # past "OHDR", version and flags
    !iszero(flags & 0x20) && (p += 16)            # access, modification, change, birth times
    !iszero(flags & 0x10) && (p += 4)             # maximum compact and minimum dense counts
    sizesize = 1 << (flags & 0x03)
    chunklen = Int(readuint(buf, p, sizesize))
    p += sizesize
    ordered = !iszero(flags & 0x04)
    push!(a.blocks, p)
    push!(a.blocks, chunklen)
    bi = 1
    while bi <= length(a.blocks)
        q = a.blocks[bi]
        stop = q + a.blocks[bi + 1]
        bi += 2
        # The checksum covers the whole block, which for the first one starts at the
        # signature rather than at the first message.
        cstart = bi == 3 ? o : q
        # A continuation block repeats the signature before its messages, and its declared
        # length covers the signature and the trailing checksum.
        if sigat(buf, q, OCHK_SIG)
            q += 4
            stop -= 4
        end
        checkblock(buf, cstart, stop, "an object header")
        while q + 4 <= stop
            mtype = Int(buf[q + 1])
            msize = Int(readuint(buf, q + 1, 2))
            d = q + 4 + (ordered ? 2 : 0)
            # A run of zero bytes is the gap HDF5 leaves before the block's checksum.
            iszero(mtype) && iszero(msize) && break
            iszero(buf[q + 4] & 0x02) ||
                error("this file shares an object header message, which is not read")
            handle_message!(a, f, mtype, d)
            q = d + msize
        end
    end
    return nothing
end

function objinfo(f::H5File, addr::Int)
    o = foff(f, addr)
    a = ObjAcc()
    if sigat(f.buf, o, OHDR_SIG)
        scan_v2!(a, f, o)
    elseif f.buf[o + 1] == 0x01 # noidiom
        scan_v1!(a, f, o)
    else
        error("unsupported object header at address ", addr)
    end
    return ObjInfo(a)
end

function heapname(f::H5File, heap::Int, nameoff::Int)
    buf = f.buf
    h = foff(f, heap)
    # "HEAP". The other structures check their own signature, and a wrong address here would
    # otherwise be read as an offset into nothing.
    (buf[h + 1] == 0x48 && buf[h + 2] == 0x45 && buf[h + 3] == 0x41 && buf[h + 4] == 0x50) || # noidiom
        error("expected a HEAP at the address the group gives for its names")
    dseg = foff(f, Int(readuint(buf, h + 8 + 2 * f.lsize, f.osize)))
    s = dseg + nameoff
    e = s
    while !iszero(buf[e + 1])
        e += 1
    end
    return String(buf[(s + 1):e])
end

"Walk a group's version-1 B-tree, appending every symbol table entry it reaches."
function walk_group!(names::Vector{String}, addrs::Vector{Int}, f::H5File, btree::Int, heap::Int)
    buf = f.buf
    todo = Int[btree]
    while !isempty(todo)
        node = foff(f, pop!(todo))
        (buf[node + 1] == 0x54 && buf[node + 2] == 0x52) || error("expected a TREE node") # noidiom
        # Node type 0 indexes a group's names; type 1 indexes the chunks of a dataset.
        iszero(buf[node + 5]) || error("expected a tree of group names, not of data chunks")
        level = Int(buf[node + 6])
        nused = Int(readuint(buf, node + 6, 2))
        p = node + 8 + 2 * f.osize
        for i in 1:nused
            child = readaddr(buf, p + f.lsize, f.osize)   # keys and children alternate
            p += f.lsize + f.osize
            child < 0 && continue
            if level > 0
                push!(todo, child)
            else
                snod = foff(f, child)
                (buf[snod + 1] == 0x53 && buf[snod + 2] == 0x4e) || error("expected a SNOD node") # noidiom
                nsym = Int(readuint(buf, snod + 6, 2))
                esz = 2 * f.osize + 24
                for k in 0:(nsym - 1)
                    e = snod + 8 + k * esz
                    push!(names, heapname(f, heap, Int(readuint(buf, e, f.osize))))
                    push!(addrs, readaddr(buf, e + f.osize, f.osize))
                end
            end
        end
    end
    return nothing
end

"""
The members of the group whose header `oi` describes. An old-style group indexes its names
through a local heap and a B-tree; a compact group carries them directly as link messages.
"""
function groupentries(f::H5File, oi::ObjInfo)
    names = String[]
    addrs = Int[]
    if oi.stab_btree >= 0
        walk_group!(names, addrs, f, oi.stab_btree, oi.stab_heap)
    else
        for (name, addr) in oi.links
            push!(names, name)
            push!(addrs, addr)
        end
    end
    return names, addrs
end

groupentries(f::H5File, addr::Int) = groupentries(f, objinfo(f, addr))

"True when this object header describes a group rather than a dataset."
isgroup(oi::ObjInfo) = oi.stab_btree >= 0 || oi.linkinfo || !isempty(oi.links)

function rootentries(f::H5File)
    oi = objinfo(f, f.root)
    isgroup(oi) || error("the root group has neither a symbol table nor link messages")
    return groupentries(f, oi)
end
