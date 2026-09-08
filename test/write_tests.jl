@testitem "written files round-trip through this package" setup = [Fixtures] begin
    using PureMAT: matwrite

    mktempdir() do dir
        path = joinpath(dir, "out.mat")
        a = [1.0 3.0; 4.0 2.0]
        b = reshape(collect(1.0:24.0), 4, 3, 2)
        i32 = Int32[1 2 3; 4 5 6]
        flags = [true false; false true]
        matwrite(path, "a" => a, "b" => b, "i32" => i32, "flags" => flags, "label" => "hello wörld")

        f = matopen(path)
        @test sort(keys(f)) == ["a", "b", "flags", "i32", "label"]
        @test matread(f, "a", Matrix{Float64}) == a
        @test matread(f, "b", Array{Float64, 3}) == b
        @test matread(f, "i32", Matrix{Int32}) == i32
        @test matread(f, "flags", Matrix{Bool}) == flags
        @test matread(f, "label", String) == "hello wörld"
        @test matsize(f, "b") == [4, 3, 2]
    end
end

@testitem "libhdf5 reads what this package writes" setup = [Fixtures] begin
    using PureMAT: matwrite
    import MAT

    # The real acceptance test. libhdf5 verifies the superblock and object header checksums,
    # so a wrong one is rejected here rather than silently tolerated, and MAT.jl on top of it
    # reconstructs the MATLAB classes from the attributes.
    mktempdir() do dir
        path = joinpath(dir, "out.mat")
        a = [1.0 3.0; 4.0 2.0]
        b = reshape(collect(1.0:24.0), 4, 3, 2)
        i32 = Int32[1 2 3; 4 5 6]
        flags = [true false; false true]
        matwrite(path, "a" => a, "b" => b, "i32" => i32, "flags" => flags, "label" => "hello wörld")

        d = MAT.matread(path)
        @test sort(collect(keys(d))) == ["a", "b", "flags", "i32", "label"]
        @test d["a"] == a
        @test d["b"] == b
        @test d["i32"] == i32
        @test d["flags"] == flags
        @test d["label"] == "hello wörld"
        @test eltype(d["flags"]) === Bool
        @test eltype(d["i32"]) === Int32
    end
end

@testitem "written files carry the MATLAB banner and a 512-byte user block" setup = [Fixtures] begin
    using PureMAT: matwrite

    mktempdir() do dir
        path = joinpath(dir, "out.mat")
        matwrite(path, "x" => [1.0])
        bytes = read(path)
        @test startswith(String(bytes[1:20]), "MATLAB 7.3 MAT-file")
        # The HDF5 signature sits after the user block, which is what makes the banner legal.
        @test bytes[513:520] == UInt8[0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a]
    end
end

@testitem "the writer refuses to emit a file it cannot describe" setup = [Fixtures] begin
    using PureMAT: matwrite, MatWriter
    @test_throws "nothing to write" matwrite(joinpath(mktempdir(), "empty.mat"), MatWriter())
end
