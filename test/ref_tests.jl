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
        path = joinpath(dir, "cases.mat")
        case(n, xf, names, tag) = Dict{String, Any}(
            "nfield" => fill(n, 1, 1),
            "wd" => Dict{String, Any}("xf" => xf, "yf" => xf .+ 10.0),
            "layer" => Dict{String, Any}("name" => names, "wr" => fill(0.5, 1, 1)),
            "tag" => tag,
        )
        MAT.matwrite(
            path,
            Dict{String, Any}(
                "cases" => Any[
                case(4.0, [1.0 2.0 3.0], Any["metal1" "via1"], "case one") case(
                    7.0, [9.0 8.0], Any["poly"], "case two",
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
        cases = matread(f, "cases", Matrix{MatRef})
        @test size(cases) == (1, 2)
        @test matread(f, cases[1, 1], "nfield", Float64) === 4.0
        @test matread(f, cases[1, 2], "nfield", Float64) === 7.0
        # The same field as the 1x1 array the file really holds.
        @test matread(f, cases[1, 1], "nfield", Matrix{Float64}) == fill(4.0, 1, 1)
    end
end

@testitem "a path goes down more than one step below a mark" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        one = matread(f, "cases", Matrix{MatRef})[1, 1]
        @test matread(f, one, "wd/xf", Matrix{Float64}) == [1.0 2.0 3.0]
        @test matread(f, one, "wd/yf", Matrix{Float64}) == [11.0 12.0 13.0]
        @test matread(f, one, "layer/wr", Float64) === 0.5
    end
end

@testitem "a cell field below a mark hands out further marks" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        one = matread(f, "cases", Matrix{MatRef})[1, 1]
        names = matread(f, one, "layer/name", Matrix{MatRef})
        @test size(names) == (1, 2)
        @test matread(f, names[1], String) == "metal1"
        @test matread(f, names[2], String) == "via1"
    end
end

@testitem "text below a mark" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        one = matread(f, "cases", Matrix{MatRef})[1, 1]
        @test matread(f, one, "tag", String) == "case one"
    end
end

@testitem "matref steps down without reading" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        one = matread(f, "cases", Matrix{MatRef})[1, 1]
        wd = matref(f, one, "wd")
        @test wd isa MatRef
        # Field order is the file's, not MATLAB's, so only the set of names is checked.
        @test sort(matkeys(f, wd)) == ["xf", "yf"]
        @test matread(f, wd, "xf", Matrix{Float64}) == [1.0 2.0 3.0]
    end
end

@testitem "a name that is not there below a mark stops with an error" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        one = matread(f, "cases", Matrix{MatRef})[1, 1]
        @test_throws "\"nope\"" matread(f, one, "nope", Float64)
        @test_throws "\"wd/nope\"" matread(f, one, "wd/nope", Matrix{Float64})
    end
end

@testitem "the type checks below a mark are the ones above it" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        one = matread(f, "cases", Matrix{MatRef})[1, 1]
        @test_throws "rank 2, not 3" matread(f, one, "wd/xf", Array{Float64, 3})
        @test_throws "datatype class" matread(f, one, "wd/xf", Matrix{Int64})
        @test_throws "not a MATLAB char array" matread(f, one, "wd/xf", String)
        # The error names the path asked for, not the mark it started from.
        @test_throws "\"wd/xf\" holds 3 values, not 1" matread(f, one, "wd/xf", Float64)
    end
end

@testitem "the macro reads below a mark too" setup = [Marks] begin
    mktempdir() do dir
        f = matopen(markfile(dir))
        one = matread(f, "cases", Matrix{MatRef})[1, 1]
        v = @matload f, one begin
            nfield = "nfield"::Float64
            xf = "wd/xf"::Matrix{Float64}
            tag = "tag"::String
        end
        @test v == (nfield = 4.0, xf = [1.0 2.0 3.0], tag = "case one")
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
