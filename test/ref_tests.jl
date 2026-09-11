# Typed reads below a mark. A cell array and a struct array both hand out marks rather than
# values, so a path has to be able to start at one instead of at the top of the file.

@testsnippet Marks begin
    using MAT73
    import MAT

    """
    A file holding a 1x2 cell of structs, each with a nested struct and a cell of text.

    MAT.jl writes it, so the bytes come from the HDF5 C library rather than from this package.
    Scalars are 1x1 arrays, which is the shape MATLAB gives them.
    """
    function markfile(dir)
        path = joinpath(dir, "runs.mat")
        entry(n, values, names, label) = Dict{String, Any}(
            "count" => fill(n, 1, 1),
            "inner" => Dict{String, Any}("values" => values, "extra" => values .+ 10.0),
            "parts" => Dict{String, Any}("name" => names, "size" => fill(0.5, 1, 1)),
            "label" => label,
        )
        MAT.matwrite(
            path,
            Dict{String, Any}(
                "runs" => Any[
                entry(4.0, [1.0 2.0 3.0], Any["first" "second"], "run one") entry(
                    7.0, [9.0 8.0], Any["only"], "run two",
                )
                ],
            ),
        )
        return path
    end
end

@testitem "a number one step below a mark" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        runs = matread(f, "runs", Matrix{MatRef})
        @test size(runs) == (1, 2)
        @test matread(f, runs[1, 1], "count", Float64) === 4.0
        @test matread(f, runs[1, 2], "count", Float64) === 7.0
        # The same field as the 1x1 array the file really holds.
        @test matread(f, runs[1, 1], "count", Matrix{Float64}) == fill(4.0, 1, 1)
    end
end

@testitem "a path goes down more than one step below a mark" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        one = matread(f, "runs", Matrix{MatRef})[1, 1]
        @test matread(f, one, "inner/values", Matrix{Float64}) == [1.0 2.0 3.0]
        @test matread(f, one, "inner/extra", Matrix{Float64}) == [11.0 12.0 13.0]
        @test matread(f, one, "parts/size", Float64) === 0.5
    end
end

@testitem "a cell field below a mark hands out further marks" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        one = matread(f, "runs", Matrix{MatRef})[1, 1]
        names = matread(f, one, "parts/name", Matrix{MatRef})
        @test size(names) == (1, 2)
        @test matread(f, names[1], String) == "first"
        @test matread(f, names[2], String) == "second"
    end
end

@testitem "text below a mark" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        one = matread(f, "runs", Matrix{MatRef})[1, 1]
        @test matread(f, one, "label", String) == "run one"
    end
end

@testitem "matref steps down without reading" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        one = matread(f, "runs", Matrix{MatRef})[1, 1]
        inner = matref(f, one, "inner")
        @test inner isa MatRef
        # Field order is the file's, not MATLAB's, so only the set of names is checked.
        @test sort(matkeys(f, inner)) == ["extra", "values"]
        @test matread(f, inner, "values", Matrix{Float64}) == [1.0 2.0 3.0]
    end
end

@testitem "a name that is not there below a mark stops with an error" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        one = matread(f, "runs", Matrix{MatRef})[1, 1]
        @test_throws "\"nope\"" matread(f, one, "nope", Float64)
        @test_throws "\"inner/nope\"" matread(f, one, "inner/nope", Matrix{Float64})
    end
end

@testitem "the type checks below a mark are the ones above it" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        one = matread(f, "runs", Matrix{MatRef})[1, 1]
        @test_throws "rank 2, not 3" matread(f, one, "inner/values", Array{Float64, 3})
        @test_throws "holds decimal numbers, not whole numbers" matread(
            f, one, "inner/values", Matrix{Int64}
        )
        @test_throws "not a MATLAB char array" matread(f, one, "inner/values", String)
        # The error names the path asked for, not the mark it started from.
        @test_throws "\"inner/values\" holds 3 values, not 1" matread(
            f, one, "inner/values", Float64
        )
    end
end

@testitem "the macro reads below a mark too" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        one = matread(f, "runs", Matrix{MatRef})[1, 1]
        v = @matload f, one begin
            count = "count"::Float64
            values = "inner/values"::Matrix{Float64}
            label = "label"::String
        end
        @test v == (count = 4.0, values = [1.0 2.0 3.0], label = "run one")
    end
end

@testitem "a field of a struct array is reached through its marks" setup = [Fixtures] begin
    # struct.mat holds s2, a 1x2 struct array, so its field "a" is an array of marks. This
    # file came from MATLAB itself.
    f = matopen(fixture("struct.mat"))
    items = matread(f, "s2/a", Matrix{MatRef})
    @test size(items) == (1, 2)
    @test matread(f, items[1], Matrix{Float64}) == fill(1.0, 1, 1)
    @test matread(f, items[2], Matrix{Float64}) == fill(2.0, 1, 1)
end
