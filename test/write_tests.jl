@testitem "written files round-trip through this package" setup = [Fixtures] begin
    using MAT73: matwrite

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
    using MAT73: matwrite
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
    using MAT73: matwrite

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
    using MAT73: matwrite, MatWriter
    @test_throws "nothing to write" matwrite(joinpath(mktempdir(), "empty.mat"), MatWriter())
end

@testitem "a named tuple writes a struct and a tuple writes a cell" setup = [Fixtures] begin
    using MAT73: matwrite
    import MAT

    mktempdir() do dir
        path = joinpath(dir, "nested.mat")
        matwrite(
            path,
            "cfg" => (gain = 2.5, mode = "fast", limits = (1.0, 10.0), inner = (n = Int32(7),)),
            "runs" => ([1.0 2.0], "second", (name = "third", ok = true)),
            "n" => 42,
        )

        # libhdf5 checks every header and then MAT.jl rebuilds the MATLAB classes, so a
        # struct, a cell and their nesting all have to be right for this to pass.
        d = MAT.matread(path)
        @test d["cfg"]["gain"] == 2.5
        @test d["cfg"]["mode"] == "fast"
        @test d["cfg"]["limits"] == Any[1.0 10.0]
        @test d["cfg"]["inner"]["n"] == 7
        @test d["runs"][1] == [1.0 2.0]
        @test d["runs"][2] == "second"
        @test d["runs"][3]["name"] == "third"
        @test d["runs"][3]["ok"] === true
        @test d["n"] == 42
    end
end

@testitem "this package reads back the structs and cells it writes" setup = [Fixtures] begin
    using MAT73: matwrite, MatRef

    mktempdir() do dir
        path = joinpath(dir, "nested.mat")
        matwrite(
            path,
            "cfg" => (gain = 2.5, mode = "fast", limits = (1.0, 10.0)),
            "runs" => ([1.0 2.0], "second"),
        )

        f = matopen(path)
        @test matkeys(f, "cfg") == ["gain", "mode", "limits"]
        @test matread(f, "cfg/gain", Matrix{Float64}) == fill(2.5, 1, 1)
        @test matread(f, "cfg/mode", String) == "fast"

        items = matread(f, "cfg/limits", Matrix{MatRef})
        @test size(items) == (1, 2)
        @test matread(f, items[1], Matrix{Float64}) == fill(1.0, 1, 1)
        @test matread(f, items[2], Matrix{Float64}) == fill(10.0, 1, 1)

        runs = matread(f, "runs", Matrix{MatRef})
        @test matread(f, runs[1], Matrix{Float64}) == [1.0 2.0]
        @test matread(f, runs[2], String) == "second"
    end
end

@testitem "a named tuple survives a round trip through a file" setup = [Fixtures] begin
    using MAT73: matwrite

    # Both halves state their types, so a program built with juliac can write a result and
    # read it back without either step working the type out while it runs.
    mktempdir() do dir
        path = joinpath(dir, "result.mat")
        result = (gain = 2.5, count = Int64(7), label = "run 3")
        matwrite(path, "gain" => result.gain, "count" => result.count, "label" => result.label)

        back = @matload path begin
            gain::Float64
            count::Int64
            label::String
        end
        @test back == result
    end
end

@testitem "the cell contents live under a name MATLAB reserves" setup = [Fixtures] begin
    using MAT73: matwrite

    mktempdir() do dir
        path = joinpath(dir, "cells.mat")
        matwrite(path, "c" => (1.0, "two"))
        f = matopen(path)
        # The items a cell points at must still be reachable by name, or the file holds
        # objects no reader can walk to.
        @test "#refs#" in keys(f)
        @test length(matkeys(f, "#refs#")) == 2
    end
end

@testitem "an empty cell array is refused rather than written wrong" setup = [Fixtures] begin
    using MAT73: matwrite, MatWriter
    @test_throws "empty cell array" push!(MatWriter(), "c", ())
end
