# Files that are damaged, unusual, or written by something other than MATLAB. The package
# prefers an error to a value it cannot stand behind, so each of these must stop rather than
# hand back numbers that look real.
#
# HDF5.jl writes the awkward cases. It drives the same C library MAT.jl does, and it can write
# shapes MATLAB never writes.

@testsnippet Strict begin
    using MAT73
    import HDF5

    "Write one file with HDF5.jl. `setup` is handed the open file to fill."
    function h5file(setup, dir, name)
        path = joinpath(dir, name)
        HDF5.h5open(setup, path, "w")
        return path
    end
end

@testitem "a damaged object header is refused, not read" setup = [Strict] begin
    using MAT73: matwrite

    mktempdir() do dir
        path = joinpath(dir, "out.mat")
        matwrite(path, "a" => [1.0 2.0; 3.0 4.0])
        bytes = read(path)

        # The running total covers the header, so one changed byte anywhere in it must fail.
        # Byte 600 is inside the first object header, past the 512-byte block and the
        # superblock.
        bytes[600] ⊻= 0xff
        bad = joinpath(dir, "bad.mat")
        write(bad, bytes)
        @test_throws "running total" matopen(bad)
    end
end

@testitem "a damaged superblock is refused, not read" setup = [Strict] begin
    using MAT73: matwrite

    mktempdir() do dir
        path = joinpath(dir, "out.mat")
        matwrite(path, "a" => [1.0])
        bytes = read(path)
        # The end-of-file address, inside the superblock's own running total.
        bytes[513 + 30] ⊻= 0xff
        bad = joinpath(dir, "bad.mat")
        write(bad, bytes)
        @test_throws "running total" matopen(bad)
    end
end

@testitem "a chunked dataset with holes is refused" setup = [Strict] begin
    mktempdir() do dir
        # Space is allocated chunk by chunk, and only one chunk is written, so 75 of the 100
        # elements were never stored. libhdf5 would give its fill value; reading the raw
        # bytes would give whatever the memory held.
        path = h5file(dir, "holes.h5") do io
            d = HDF5.create_dataset(
                io, "a", HDF5.datatype(Float64), HDF5.dataspace((10, 10));
                chunk = (5, 5), alloc_time = :incremental,
            )
            d[1:5, 1:5] = ones(5, 5)
        end
        f = matopen(path)
        @test_throws "never been written" matread(f, "a", Matrix{Float64})
    end
end

@testitem "numbers stored the other way round are refused" setup = [Strict] begin
    mktempdir() do dir
        path = h5file(dir, "be.h5") do io
            d = HDF5.create_dataset(
                io, "a", HDF5.Datatype(HDF5.API.H5T_IEEE_F64BE), HDF5.dataspace((1, 2)),
            )
            HDF5.write_dataset(d, HDF5.datatype(Float64), [1.0 2.0])
        end
        f = matopen(path)
        @test_throws "most significant byte first" matread(f, "a", Matrix{Float64})
    end
end

@testitem "a chunk that inflates to the wrong size is refused" setup = [Strict] begin
    using MAT73: inflate
    import ChunkCodecLibZlib as Z

    # The compressor reports the size it produced; a buffer of the wrong size is not a
    # readable chunk either way round.
    src = Z.encode(Z.ZlibEncodeOptions(), collect(0x00:0x63))
    @test length(inflate(src, 100)) == 100
    @test_throws "chunk" inflate(src, 50)
    @test_throws "not the 1000 bytes" inflate(src, 1000)
end

@testitem "the writer refuses what MATLAB cannot read back" setup = [Strict] begin
    using MAT73: matwrite, MatWriter

    dir = mktempdir()
    @test_throws "already written here" matwrite(
        joinpath(dir, "dup.mat"), "a" => 1.0, "a" => 2.0
    )
    @test_throws "may not hold" push!(MatWriter(), "a/b", 1.0)
    # Int128 has no MATLAB class, so no method takes it.
    @test_throws MethodError push!(MatWriter(), "a", Int128[1])
end

@testitem "libhdf5 opens the empty arrays this package writes" setup = [Strict] begin
    using MAT73: matwrite
    import MAT

    # A dataset of 0 bytes is not something the HDF5 C library will open. MATLAB stores the
    # dimensions instead, which is also how the shape survives.
    mktempdir() do dir
        path = joinpath(dir, "empty.mat")
        matwrite(path, "e" => zeros(0, 3), "s" => "", "z" => Int32[])

        d = MAT.matread(path)
        @test size(d["e"]) == (0, 3)
        @test isempty(d["s"])

        f = matopen(path)
        @test matsize(f, "e") == [0, 3]
        @test matread(f, "e", Matrix{Float64}) == zeros(0, 3)
        @test matread(f, "s", String) == ""
    end
end

@testitem "a struct with no fields is still a struct" setup = [Strict] begin
    using MAT73: matwrite

    # A group with no links carries only a link-info message, which is the one thing that
    # says it is a group and not a dataset.
    mktempdir() do dir
        path = joinpath(dir, "bare.mat")
        matwrite(path, "s" => NamedTuple())
        f = matopen(path)
        @test matkeys(f, "s") == String[]
        @test matread(f, "s") == Dict{String, Any}()
    end
end
