# Chunked storage: a version-1 B-tree indexes the chunks, each of which may have been put
# through the filter pipeline. MATLAB compresses anything beyond a few hundred bytes, so this
# is the path almost every real array takes.

"One leaf entry of a chunk B-tree."
struct ChunkRef
    addr::Int          # file offset of the chunk's stored bytes
    nbytes::Int        # stored size, after filtering
    mask::Int          # bit i set means filter i was skipped for this chunk
    off::Vector{Int}   # element offsets, in HDF5 dimension order
end

"Collect every leaf entry of the chunk B-tree rooted at `btree`."
function chunkrefs(f::H5File, btree::Int, ndl::Int)
    buf = f.buf
    refs = ChunkRef[]
    todo = Int[btree]
    keysz = 8 + ndl * 8
    while !isempty(todo)
        node = foff(f, pop!(todo))
        (buf[node + 1] == 0x54 && buf[node + 2] == 0x52) || error("expected a TREE node") # noidiom
        buf[node + 5] == 0x01 || error("expected a chunk B-tree, not a group B-tree") # noidiom
        level = Int(buf[node + 6])
        nused = Int(readuint(buf, node + 6, 2))
        p = node + 8 + 2 * f.osize
        for i in 1:nused
            nbytes = Int(readuint(buf, p, 4))
            mask = Int(readuint(buf, p + 4, 4))
            off = Vector{Int}(undef, ndl)
            for k in 1:ndl
                off[k] = Int(readuint(buf, p + 8 + (k - 1) * 8, 8))
            end
            child = readaddr(buf, p + keysz, f.osize)
            p += keysz + f.osize
            child < 0 && continue
            if level > 0
                push!(todo, child)
            else
                push!(refs, ChunkRef(foff(f, child), nbytes, mask, off))
            end
        end
    end
    return refs
end

const ZLIB_OPTS = ZlibDecodeOptions()

function inflate(src::Vector{UInt8}, nbytes::Int)
    dst = Vector{UInt8}(undef, nbytes)
    got = try_decode!(ZLIB_OPTS, dst, src)
    isnothing(got) && error("chunk did not inflate to the expected ", nbytes, " bytes")
    return dst
end

"""
Undo the HDF5 shuffle filter, which groups the first byte of every `s`-byte element, then
every second byte, and so on. Any trailing bytes past the last whole element are left where
they are, which is what the filter does on the way in.
"""
function unshuffle(v::Vector{UInt8}, s::Int)
    n = length(v)
    (s <= 1 || n < s) && return v
    m = n ÷ s
    out = Vector{UInt8}(undef, n)
    for j in 0:(s - 1)
        base = j * m
        for i in 0:(m - 1)
            out[i * s + j + 1] = v[base + i + 1]
        end
    end
    for i in (m * s):(n - 1)
        out[i + 1] = v[i + 1]
    end
    return out
end

"Reverse the filter pipeline for one chunk. Filters are applied in order on the way in."
function decodechunk(f::H5File, oi::ObjInfo, ref::ChunkRef, rawlen::Int)
    bytes = f.buf[(ref.addr + 1):(ref.addr + ref.nbytes)]
    for i in oi.nfilters:-1:1
        iszero((ref.mask >> (i - 1)) & 1) || continue   # this filter was skipped for this chunk
        fid = oi.filter_ids[i]
        if fid == FILTER_DEFLATE
            bytes = inflate(bytes, rawlen)
        elseif fid == FILTER_SHUFFLE
            bytes = unshuffle(bytes, oi.filter_cd1[i])
        else
            error("unsupported HDF5 filter id ", fid)
        end
    end
    return bytes
end

"""
Fill `out` from chunked storage. `out` is indexed in HDF5's own element order, the same
order the contiguous path uses, so the MATLAB array comes out without a transpose.
"""
function readchunked!(out::Array{T, N}, f::H5File, oi::ObjInfo) where {T, N}
    nd = oi.nd
    sz = sizeof(T)
    # HDF5 stores one chunk dimension per dataspace dimension plus a trailing element size.
    oi.chunk_ndl == nd + 1 || error("chunk dimensionality does not match the dataspace rank")

    dstride = Vector{Int}(undef, nd)
    cstride = Vector{Int}(undef, nd)
    a = 1
    b = 1
    for k in nd:-1:1
        dstride[k] = a
        a *= oi.dims[k]
        cstride[k] = b
        b *= oi.chunk_dims[k]
    end
    cn = b                       # elements in a whole chunk
    rawlen = cn * sz

    for ref in chunkrefs(f, oi.chunk_btree, oi.chunk_ndl)
        bytes = decodechunk(f, oi, ref, rawlen)
        length(bytes) >= rawlen || error("decoded chunk is shorter than the chunk extent")
        for li in 0:(cn - 1)
            # A chunk at the edge of the dataset is stored whole and padded; the elements
            # past the dataset extent are discarded here rather than written out of range.
            gidx = 0
            inbounds = true
            for k in 1:nd
                gk = ref.off[k] + (li ÷ cstride[k]) % oi.chunk_dims[k]
                if gk >= oi.dims[k]
                    inbounds = false
                    break
                end
                gidx += gk * dstride[k]
            end
            inbounds || continue
            out[gidx + 1] = readelem(T, bytes, li * sz)
        end
    end
    return out
end
