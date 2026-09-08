# The subset of HDF5 that MATLAB's v7.3 writer emits: a 512-byte user block, superblock
# version 0, version-1 object headers, old-style groups (local heap + version-1 B-tree +
# symbol table nodes), and contiguous or compact data layout.
#
# Everything here is written to stay statically resolvable under `juliac --trim=safe`:
# concrete field types, no closures over loop-mutated locals, no runtime-constructed types.

const H5SIG = (0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a)

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

# The object-header fields a raw array read needs. A fixed layout keeps inference concrete.
struct ObjInfo
    stab_btree::Int
    stab_heap::Int
    layout::Int
    data_off::Int    # 0-based file offset of the raw data, -1 if unallocated
    data_size::Int   # bytes
    nd::Int
    dims::NTuple{MAXRANK, Int}
    dt_class::Int
    dt_size::Int     # bytes per element
    dt_signed::Bool  # meaningful only for DT_FIXED
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
    iszero(buf[sb + 9]) || error("unsupported superblock version; only version 0 is read")
    osize = Int(buf[sb + 14])
    lsize = Int(buf[sb + 15])
    p = sb + 24                       # past prefix, K values and consistency flags
    baseaddr = Int(readuint(buf, p, osize))
    # base, free-space, end-of-file and driver-info addresses, then the root symbol table entry
    rootent = p + 4 * osize
    root = readaddr(buf, rootent + osize, osize)
    return H5File(buf, sb, osize, lsize, baseaddr, root)
end

@inline foff(f::H5File, addr::Int) = f.baseaddr + addr

# Top-level rather than closures: a closure capturing a loop-mutated local boxes it, which
# makes the enclosing frame unresolvable under `--trim=safe`.
@inline function dimat(buf::Vector{UInt8}, d::Int, k::Int, nd::Int, ls::Int)::Int
    return k <= nd ? Int(readuint(buf, d + 8 + (k - 1) * ls, ls)) : 0
end

"MATLAB dimension `k`, recovered from the reversed dimensions HDF5 stores."
@inline function matdim(dims::NTuple{MAXRANK, Int}, k::Int, nd::Int)::Int
    return k <= nd ? dims[nd - k + 1] : 1
end

function objinfo(f::H5File, addr::Int)
    buf = f.buf
    o = foff(f, addr)
    buf[o + 1] == 0x01 || error("unsupported object header version; only version 1 is read") # noidiom
    nmsg = Int(readuint(buf, o + 2, 2))
    # 12-byte prefix, messages begin at the next 8-byte boundary. Continuation blocks are
    # appended as (start, length) pairs while scanning.
    blocks = Int[o + 16, Int(readuint(buf, o + 8, 4))]

    stab_btree = -1
    stab_heap = -1
    layout = LAYOUT_NONE
    data_off = -1
    data_size = 0
    nd = 0
    dims = (0, 0, 0, 0, 0, 0, 0, 0)
    dt_class = -1
    dt_size = 0
    dt_signed = false

    seen = 0
    bi = 1
    while bi <= length(blocks) && seen < nmsg
        p = blocks[bi]
        stop = p + blocks[bi + 1]
        bi += 2
        while p + 8 <= stop && seen < nmsg
            mtype = Int(readuint(buf, p, 2))
            msize = Int(readuint(buf, p + 2, 2))
            d = p + 8
            seen += 1
            if mtype == 1                    # dataspace
                buf[d + 1] == 0x01 || error("unsupported dataspace version") # noidiom
                nd = Int(buf[d + 2])
                nd <= MAXRANK || error("dataspace rank above $MAXRANK is not supported")
                ls = f.lsize
                dims = (
                    dimat(buf, d, 1, nd, ls), dimat(buf, d, 2, nd, ls),
                    dimat(buf, d, 3, nd, ls), dimat(buf, d, 4, nd, ls),
                    dimat(buf, d, 5, nd, ls), dimat(buf, d, 6, nd, ls),
                    dimat(buf, d, 7, nd, ls), dimat(buf, d, 8, nd, ls),
                )
            elseif mtype == 3                # datatype
                # Byte 0 packs version in the high nibble and class in the low nibble.
                dt_class = Int(buf[d + 1] & 0x0f)
                dt_signed = !iszero((buf[d + 2] >> 3) & 0x01)
                dt_size = Int(readuint(buf, d + 4, 4))
            elseif mtype == 8                # data layout
                v = Int(buf[d + 1])
                if v == 3 || v == 4
                    layout = Int(buf[d + 2])
                    if layout == LAYOUT_COMPACT
                        data_size = Int(readuint(buf, d + 2, 2))
                        data_off = d + 4
                    elseif layout == LAYOUT_CONTIGUOUS
                        a = readaddr(buf, d + 2, f.osize)
                        data_off = a < 0 ? -1 : foff(f, a)
                    end
                elseif v == 1 || v == 2
                    ndl = Int(buf[d + 2])
                    layout = Int(buf[d + 3])
                    q = d + 8
                    if layout != LAYOUT_COMPACT
                        a = readaddr(buf, q, f.osize)
                        data_off = a < 0 ? -1 : foff(f, a)
                        q += f.osize
                    end
                    q += ndl * 4                 # dimension sizes, in elements
                    if layout == LAYOUT_COMPACT
                        data_size = Int(readuint(buf, q, 4))
                        data_off = q + 4
                    end
                else
                    error("unsupported data layout version")
                end
            elseif mtype == 16               # object header continuation
                ca = readaddr(buf, d, f.osize)
                cl = Int(readuint(buf, d + f.osize, f.lsize))
                if ca >= 0
                    push!(blocks, foff(f, ca))
                    push!(blocks, cl)
                end
            elseif mtype == 17               # symbol table
                stab_btree = readaddr(buf, d, f.osize)
                stab_heap = readaddr(buf, d + f.osize, f.osize)
            end
            p = d + msize
        end
    end
    # A contiguous extent comes from dataspace times datatype: the layout message's stored
    # size counts elements in versions 1 and 2 but bytes in version 3.
    if layout == LAYOUT_CONTIGUOUS
        n = 1
        for k in 1:nd
            n *= dims[k]
        end
        data_size = n * dt_size
    end
    return ObjInfo(stab_btree, stab_heap, layout, data_off, data_size, nd, dims, dt_class, dt_size, dt_signed)
end

function heapname(f::H5File, heap::Int, nameoff::Int)
    buf = f.buf
    h = foff(f, heap)
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

function rootentries(f::H5File)
    names = String[]
    addrs = Int[]
    oi = objinfo(f, f.root)
    oi.stab_btree < 0 && error("root group has no symbol table; new-style groups are not read yet")
    walk_group!(names, addrs, f, oi.stab_btree, oi.stab_heap)
    return names, addrs
end
