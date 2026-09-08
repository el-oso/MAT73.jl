# Cell arrays and structs. Both are containers whose members have no common type, so they are
# read as references and paths rather than as a single value.

@testitem "a cell array reads as references that can be followed" setup = [Fixtures] begin
    f = matopen(fixture("cell.mat"))
    ref = oracle("cell.mat", "cell")

    cells = matread(f, "cell", Matrix{MatRef})
    @test size(cells) == size(ref)

    # cell.mat holds 1.0, 2.01, a char row, and a nested cell of two char rows.
    @test matread(f, cells[1], Matrix{Float64}) == boxed(ref[1])
    @test matread(f, cells[2], Matrix{Float64}) == boxed(ref[2])
    @test matread(f, cells[3], String) == ref[3]

    using MAT73: MAT_DOUBLE, MAT_CHAR, MAT_CELL
    @test matclass(f, cells[1]) == MAT_DOUBLE
    @test matclass(f, cells[3]) == MAT_CHAR
    @test matclass(f, cells[4]) == MAT_CELL

    # A nested cell is followed the same way.
    inner = matread(f, cells[4], Matrix{MatRef})
    @test length(inner) == 2
    @test matread(f, inner[1], String) == ref[4][1]
    @test matread(f, inner[2], String) == ref[4][2]
end

@testitem "struct fields are reached by path" setup = [Fixtures] begin
    f = matopen(fixture("struct.mat"))
    ref = oracle("struct.mat", "s")

    @test sort(matkeys(f, "s")) == sort(collect(keys(ref)))
    @test matread(f, "s/a", Matrix{Float64}) == boxed(ref["a"])
    @test matread(f, "s/b", Matrix{Float64}) == boxed(ref["b"])
    @test matread(f, "s/c", Matrix{Float64}) == boxed(ref["c"])
    @test matsize(f, "s/c") == collect(size(boxed(ref["c"])))
end

@testitem "a struct array's fields are reference arrays" setup = [Fixtures] begin
    # In s2 each field holds one reference per element of the struct array.
    f = matopen(fixture("struct.mat"))
    @test matkeys(f, "s2") == ["a"]
    refs = matread(f, "s2/a", Matrix{MatRef})
    @test length(refs) == 2

    ref = oracle("struct.mat", "s2")
    for (i, r) in enumerate(refs)
        @test matread(f, r, Matrix{Float64}) == boxed(ref["a"][i])
    end
end

@testitem "matkeys lists the top level when given no path" setup = [Fixtures] begin
    f = matopen(fixture("simple.mat"))
    @test matkeys(f, "") == keys(f)
end

@testitem "a missing field says which path failed" setup = [Fixtures] begin
    f = matopen(fixture("struct.mat"))
    @test_throws "s/nope" matread(f, "s/nope", Matrix{Float64})
end
