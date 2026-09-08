# Jenkins lookup3 `hashlittle`, which is the checksum HDF5 stores in its version-2 metadata
# structures. Superblock version 2 and version-2 object headers are rejected by libhdf5 if it
# does not match, so this has to agree with the reference implementation bit for bit.

@inline rot(x::UInt32, k::Int) = bitrotate(x, k)

@inline function mix(a::UInt32, b::UInt32, c::UInt32)
    a -= c; a ⊻= rot(c, 4); c += b
    b -= a; b ⊻= rot(a, 6); a += c
    c -= b; c ⊻= rot(b, 8); b += a
    a -= c; a ⊻= rot(c, 16); c += b
    b -= a; b ⊻= rot(a, 19); a += c
    c -= b; c ⊻= rot(b, 4); b += a
    return a, b, c
end

@inline function final(a::UInt32, b::UInt32, c::UInt32)
    c ⊻= b; c -= rot(b, 14)
    a ⊻= c; a -= rot(c, 11)
    b ⊻= a; b -= rot(a, 25)
    c ⊻= b; c -= rot(b, 16)
    a ⊻= c; a -= rot(c, 4)
    b ⊻= a; b -= rot(a, 14)
    c ⊻= b; c -= rot(b, 24)
    return c
end

@inline word(v::Vector{UInt8}, i::Int) =
    UInt32(v[i + 1]) | (UInt32(v[i + 2]) << 8) | (UInt32(v[i + 3]) << 16) | (UInt32(v[i + 4]) << 24)

"Checksum of `v[first+1 : first+len]`, as HDF5 computes it for its own metadata."
function checksum(v::Vector{UInt8}, first::Int, len::Int)
    a = b = c = 0xdeadbeef + UInt32(len)
    p = first
    n = len
    while n > 12
        a += word(v, p)
        b += word(v, p + 4)
        c += word(v, p + 8)
        a, b, c = mix(a, b, c)
        p += 12
        n -= 12
    end
    iszero(n) && return c
    # The tail is folded in byte by byte, most significant first within each word.
    n >= 12 && (c += UInt32(v[p + 12]) << 24)
    n >= 11 && (c += UInt32(v[p + 11]) << 16)
    n >= 10 && (c += UInt32(v[p + 10]) << 8)
    n >= 9 && (c += UInt32(v[p + 9]))
    n >= 8 && (b += UInt32(v[p + 8]) << 24)
    n >= 7 && (b += UInt32(v[p + 7]) << 16)
    n >= 6 && (b += UInt32(v[p + 6]) << 8)
    n >= 5 && (b += UInt32(v[p + 5]))
    n >= 4 && (a += UInt32(v[p + 4]) << 24)
    n >= 3 && (a += UInt32(v[p + 3]) << 16)
    n >= 2 && (a += UInt32(v[p + 2]) << 8)
    n >= 1 && (a += UInt32(v[p + 1]))
    return final(a, b, c)
end
