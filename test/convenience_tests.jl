# The short reads. They work out the type from the file, so they are compared against MAT.jl,
# which does the same thing.

@testitem "reading a whole file matches the oracle" setup = [Fixtures] begin
    import MAT
    for file in ("simple.mat", "array.mat", "logical.mat", "complex.mat")
        path = fixture(file)
        ours = matread(path)
        theirs = MAT.matread(path)
        @test sort(collect(keys(ours))) == sort(collect(keys(theirs)))
        for name in keys(ours)
            # MAT.jl unwraps a 1x1 to a scalar; a raw read keeps it a matrix.
            @test ours[name] == boxed(theirs[name])
        end
    end
end

@testitem "one variable, without giving the type" setup = [Fixtures] begin
    f = matopen(fixture("simple.mat"))
    @test matread(f, "double") == fill(1.0, 1, 1)
    @test eltype(matread(f, "int16")) === Int16
    @test eltype(matread(f, "single")) === Float32
    @test eltype(matread(f, "logical")) === Bool

    g = matopen(fixture("array.mat"))
    @test matread(g, "a2x2") == [1.0 3.0; 4.0 2.0]
    @test ndims(matread(g, "a2x2x2")) == 3
    @test matread(g, "string") isa String
end

@testitem "a struct reads as a Dict" setup = [Fixtures] begin
    f = matopen(fixture("struct.mat"))
    s = matread(f, "s")
    @test s isa Dict{String, Any}
    @test sort(collect(keys(s))) == ["a", "b", "c"]
    @test s["a"] == fill(1.0, 1, 1)
end

@testitem "a cell array reads as an Array of values" setup = [Fixtures] begin
    f = matopen(fixture("cell.mat"))
    c = matread(f, "cell")
    ref = oracle("cell.mat", "cell")
    @test size(c) == size(ref)
    @test c[1] == boxed(ref[1])
    @test c[3] == ref[3]          # text comes back as a String
    @test c[4] isa AbstractArray  # a cell inside a cell
end

@testitem "an object reads as a Dict of its properties" setup = [Fixtures] begin
    f = matopen(fixture("user_defined_classdefs.mat"))
    o = matread(f, "obj_with_vals")
    @test o isa Dict{String, Any}
    @test sort(collect(keys(o))) == ["a", "b", "c"]
    @test o["a"] == fill(10.0, 1, 1)

    g = matopen(fixture("dynamicprops.mat"))
    d = matread(g, "obj")
    @test d["Name"] == "Example"
    @test d["DynamicData"] == fill(42.0, 1, 1)
end

@testitem "the whole-file read skips MATLAB's own entries" setup = [Fixtures] begin
    d = matread(fixture("cell.mat"))
    @test !any(startswith(k, "#") for k in keys(d))
    @test haskey(d, "cell")
end
