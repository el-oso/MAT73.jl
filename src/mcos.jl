# MATLAB's class object system, as stored in a v7.3 file.
#
# A variable holding a `classdef` instance carries no data of its own: it is a `uint32` array
# of indices, and the values live in `#subsystem#`. In this format the subsystem's
# `FileWrapper__` is an ordinary HDF5 reference array, so all but one of its cells are read by
# the machinery already here. The exception is its first cell, a `uint8` blob holding the
# tables that link a variable to its class and its property values, and that blob is what this
# file parses.
#
# The layout is not documented by MathWorks. It was reverse-engineered by the community; see
# https://github.com/foreverallama/matio/blob/main/docs/subsystem_data_format.md
# Fields whose meaning is still unknown are read past rather than interpreted.

"The version this parser understands. MATLAB has written 4 since the format appeared."
const MCOS_VERSION = 4

"Every MATLAB object variable begins with this tag in place of data."
const MCOS_IDENTIFIER = 0xdd000000

"One entry of an object's property map: a name, how to interpret the value, and the value."
const McosProp = Tuple{Int, Int, Int}

# How to read a property's value.
const MCOS_ENUM = 0       # the value indexes the name table
const MCOS_CELL = 1       # the value indexes the cell array, where 0 means cell 3
const MCOS_ATTR = 2       # the value is the value

"""
The tables that link an object to its class and its properties. Indices into `names` are
one-based with zero meaning absent, which is how the blob stores them.
"""
struct McosTables
    names::Vector{String}
    class_namespace::Vector{Int}   # per class id
    class_name::Vector{Int}
    object_class::Vector{Int}      # per object id
    object_normal::Vector{Int}
    object_save::Vector{Int}
    object_dependency::Vector{Int}
    normal_props::Vector{Vector{McosProp}}   # per normal-object id
    save_props::Vector{Vector{McosProp}}     # per saveobj id
    dynamic::Vector{Vector{Int}}   # per dependency id, the object ids of its dynamic properties
end

"The subsystem, parsed once per file: its cell array and the tables from the first cell."
struct McosState
    cells::Vector{MatRef}
    tables::McosTables
end

@inline mcosword(blob::Vector{UInt8}, i::Int) = Int(readuint(blob, 4i, 4))

"Names are NUL-terminated and run from the end of the header to the first region."
function mcos_names(blob::Vector{UInt8}, first_region::Int, count::Int)
    names = String[]
    s = 40                       # version, name count and eight region offsets
    while length(names) < count && s < first_region
        e = s
        while e < length(blob) && !iszero(blob[e + 1])
            e += 1
        end
        e > s && push!(names, String(blob[(s + 1):e]))
        s = e + 1
    end
    return names
end

"""
Read one region of property maps. Each block is a count followed by that many triples, padded
so the next block starts on an eight-byte boundary.
"""
function mcos_propregion(blob::Vector{UInt8}, first::Int, last::Int)
    blocks = Vector{McosProp}[]
    p = first
    while p + 4 <= last
        n = mcosword(blob, p ÷ 4)
        props = McosProp[]
        q = p + 4
        for _ in 1:n
            push!(props, (mcosword(blob, q ÷ 4), mcosword(blob, q ÷ 4 + 1), mcosword(blob, q ÷ 4 + 2)))
            q += 12
        end
        push!(blocks, props)
        # Round up to the next eight-byte boundary.
        p = q + mod(-q, 8)
    end
    return blocks
end

"""
Read the region listing each object's dynamic properties: a count followed by that many
object ids, padded so the next block starts on an eight-byte boundary. Blocks are ordered by
dependency id, and the first is empty.
"""
function mcos_dynregion(blob::Vector{UInt8}, first::Int, last::Int)
    blocks = Vector{Int}[]
    p = first
    while p + 4 <= last
        n = mcosword(blob, p ÷ 4)
        ids = Int[]
        q = p + 4
        for _ in 1:n
            push!(ids, mcosword(blob, q ÷ 4))
            q += 4
        end
        push!(blocks, ids)
        p = q + mod(-q, 8)
    end
    return blocks
end

function mcos_tables(blob::Vector{UInt8})
    length(blob) >= 40 || error("the subsystem metadata block is too short to hold a header")
    version = mcosword(blob, 0)
    version == MCOS_VERSION ||
        error("unsupported MATLAB object metadata version ", version, "; only ", MCOS_VERSION, " is read")
    ncount = mcosword(blob, 1)
    offsets = [mcosword(blob, 1 + k) for k in 1:8]
    # The regions follow one another in order. A region that ran backwards or past the end
    # would read as empty tables, and every lookup after that would report a missing name
    # rather than a damaged file.
    for k in 1:8
        offsets[k] >= 40 ||
            error("the subsystem metadata puts region ", k, " inside its own header")
        offsets[k] <= length(blob) ||
            error("the subsystem metadata puts region ", k, " past the end of the block")
        (k == 1 || offsets[k] >= offsets[k - 1]) ||
            error("the subsystem metadata regions are not in order")
    end

    names = mcos_names(blob, offsets[1], ncount)
    length(names) == ncount ||
        error("expected ", ncount, " names in the subsystem metadata, found ", length(names))

    # Classes: four words each, the first block a placeholder so that ids are one-based.
    class_namespace = Int[]
    class_name = Int[]
    for b in 0:((offsets[2] - offsets[1]) ÷ 16 - 1)
        q = offsets[1] ÷ 4 + 4b
        push!(class_namespace, mcosword(blob, q))
        push!(class_name, mcosword(blob, q + 1))
    end

    # Objects: six words each, likewise one-based.
    object_class = Int[]
    object_save = Int[]
    object_normal = Int[]
    object_dependency = Int[]
    for b in 0:((offsets[4] - offsets[3]) ÷ 24 - 1)
        q = offsets[3] ÷ 4 + 6b
        push!(object_class, mcosword(blob, q))
        push!(object_save, mcosword(blob, q + 3))
        push!(object_normal, mcosword(blob, q + 4))
        push!(object_dependency, mcosword(blob, q + 5))
    end

    save_props = mcos_propregion(blob, offsets[2], offsets[3])
    normal_props = mcos_propregion(blob, offsets[4], offsets[5])
    dynamic = mcos_dynregion(blob, offsets[5], offsets[6])
    return McosTables(
        names, class_namespace, class_name,
        object_class, object_normal, object_save, object_dependency,
        normal_props, save_props, dynamic,
    )
end

"Parse the subsystem, or return an empty state when the file holds no MATLAB objects."
function readmcos(f)
    for i in eachindex(f.names)
        f.names[i] == "#subsystem#" || continue
        subs = groupentries(f.h5, f.addrs[i])
        for j in eachindex(subs[1])
            subs[1][j] == "MCOS" || continue
            oi = objinfo(f.h5, subs[2][j])
            cells = vec(readvalues(f, oi, "MCOS", Matrix{MatRef}))
            isempty(cells) && break
            # The metadata cell is a 1xN uint8 dataset.
            blob = vec(readarray(f, cells[1], Matrix{UInt8}))
            return McosState(cells, mcos_tables(blob))
        end
    end
    empty = McosTables(
        String[], Int[], Int[], Int[], Int[], Int[], Int[],
        Vector{McosProp}[], Vector{McosProp}[], Vector{Int}[],
    )
    return McosState(MatRef[], empty)
end

"The subsystem, parsed on first use."
function mcos(f)
    isempty(f.mcos) && push!(f.mcos, readmcos(f))
    return f.mcos[1]
end

# Ids in the blob count from zero and the tables reserve their first entry as a placeholder,
# so an id of `n` is the table's element `n + 1`.
@inline atid(v::Vector{Int}, id::Int) = (id >= 0 && id + 1 <= length(v)) ? v[id + 1] : 0

"Full class name of a class id, e.g. `TestClasses.BasicClass`."
function mcos_classname(t::McosTables, classid::Int)
    name = atid(t.class_name, classid)
    iszero(name) && return ""
    ns = atid(t.class_namespace, classid)
    return iszero(ns) ? t.names[name] : string(t.names[ns], ".", t.names[name])
end

"Class id of an object id."
mcos_objectclass(t::McosTables, objid::Int) = atid(t.object_class, objid)

"""
The object ids an object variable refers to.

The variable holds no data: it is `0xdd000000`, a dimension count, those dimensions, one
object id per element, and finally the class id.
"""
function mcos_objectids(v::Vector{UInt32})
    length(v) >= 3 || return Int[]
    v[1] == MCOS_IDENTIFIER || return Int[]
    nd = Int(v[2])
    n = 1
    for k in 1:nd
        n *= Int(v[2 + k])
    end
    first = 3 + nd
    last = first + n - 1
    last < length(v) || return Int[]     # the class id follows, so the ids stop before the end
    return [Int(v[i]) for i in first:last]
end

"""
The object ids of an object's dynamic properties, those added with `addprop`. Each is itself
an object, of class `meta.DynamicProperty`, holding the property's name and value.
"""
function mcos_dynamicprops(t::McosTables, objid::Int)
    dep = atid(t.object_dependency, objid)
    dep + 1 <= length(t.dynamic) && return t.dynamic[dep + 1]
    return Int[]
end

"The property map of one object, following its saveobj id when it has one."
function mcos_props(t::McosTables, objid::Int)
    save = atid(t.object_save, objid)
    if !iszero(save)
        save + 1 <= length(t.save_props) && return t.save_props[save + 1]
        return McosProp[]
    end
    normal = atid(t.object_normal, objid)
    normal + 1 <= length(t.normal_props) && return t.normal_props[normal + 1]
    return McosProp[]
end
