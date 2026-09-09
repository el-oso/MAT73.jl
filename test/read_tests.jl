@testsnippet Fixtures begin
    using MAT73
    using MAT: matopen as h5_matopen, read as h5_read

    const FIXTURES = joinpath(@__DIR__, "fixtures", "v7.3")
    fixture(name) = joinpath(FIXTURES, name)

    "Read `name` through MAT.jl, i.e. through libhdf5 — an oracle independent of this package."
    function oracle(file, name)
        return h5_matopen(io -> h5_read(io, name), fixture(file))
    end

    "MAT.jl unwraps a 1x1 variable to a scalar; a raw read keeps it a matrix. Text is a
    scalar in both, so it is left alone."
    boxed(x) = (x isa AbstractArray || x isa AbstractString) ? x : fill(x, 1, 1)
end

@testitem "variable names match the oracle" setup = [Fixtures] begin
    for file in ("simple.mat", "array.mat", "logical.mat", "complex.mat", "char_unicode.mat")
        f = matopen(fixture(file))
        expected = h5_matopen(keys, fixture(file))
        @test sort(keys(f)) == sort(collect(expected))
    end
end

@testitem "numeric values match the oracle" setup = [Fixtures] begin
    # (file, variable, element type). MAT.jl unwraps a 1x1 to a scalar, so the comparison
    # below wraps it back up rather than asking this package to guess.
    cases = [
        ("simple.mat", "double", Float64), ("simple.mat", "single", Float32),
        ("simple.mat", "int8", Int8), ("simple.mat", "int16", Int16),
        ("simple.mat", "int32", Int32), ("simple.mat", "int64", Int64),
        ("simple.mat", "uint8", UInt8), ("simple.mat", "uint16", UInt16),
        ("simple.mat", "uint32", UInt32), ("simple.mat", "uint64", UInt64),
        ("array.mat", "a1x2", Float64), ("array.mat", "a2x1", Float64),
        ("array.mat", "a2x2", Float64), ("array.mat", "a2x2x2", Float64),
    ]
    for (file, name, T) in cases
        ref = oracle(file, name)
        refa = ref isa AbstractArray ? ref : fill(ref, 1, 1)
        f = matopen(fixture(file))
        got = matread(f, name, Array{T, ndims(refa)})
        @test got == refa
        @test matsize(f, name) == collect(size(refa))
    end
end

@testitem "a2x2 is not symmetric, so element order is checked too" setup = [Fixtures] begin
    # A sum or a symmetric matrix would hide a transposed read.
    f = matopen(fixture("array.mat"))
    A = matread(f, "a2x2", Matrix{Float64})
    @test A == [1.0 3.0; 4.0 2.0]
    @test A[2, 1] == 4.0
end

@testitem "a mismatched datatype is an error, never a reinterpretation" setup = [Fixtures] begin
    f = matopen(fixture("simple.mat"))
    @test_throws "4-byte elements, not 8" matread(f, "single", Matrix{Float64})
    @test_throws "datatype class" matread(f, "double", Matrix{Int64})
    @test_throws "opposite signedness" matread(f, "int32", Matrix{UInt32})
    @test_throws "rank" matread(f, "double", Vector{Float64})
    @test_throws "no variable or field named" matread(f, "nope", Matrix{Float64})
end

@testitem "chunked and deflated data matches the oracle" setup = [Fixtures] begin
    # Every MATLAB array beyond a few hundred bytes takes this path.
    f = matopen(fixture("partial.mat"))
    for name in ("var1", "var2")
        ref = oracle("partial.mat", name)
        got = matread(f, name, Matrix{Float64})
        @test size(got) == size(ref)
        @test got == ref
    end
end

@testitem "shuffle, partial edge chunks and a multi-node chunk B-tree" setup = [Fixtures] begin
    # s_h1.mat stores the same data as partial.mat under 7x13 chunks with shuffle+deflate,
    # so both dimensions have a partial edge chunk and the B-tree has more than one node.
    ref = oracle("partial.mat", "var1")
    path = joinpath(@__DIR__, "fixtures", "stress", "s_h1.mat")
    got = matread(matopen(path), "var1", Matrix{Float64})
    @test got == ref
end

@testitem "a path, a name and a type read in one step" setup = [Fixtures] begin
    path = fixture("simple.mat")
    f = matopen(path)
    @test matread(path, "double", Matrix{Float64}) == matread(f, "double", Matrix{Float64})

    text = fixture("string.mat")
    @test matread(text, "simple_string", String) == oracle("string.mat", "simple_string")

    # The values are copied out of the file, so they outlive the handle the call made.
    A = matread(path, "double", Matrix{Float64})
    GC.gc()
    @test A == matread(f, "double", Matrix{Float64})

    @test_throws "no variable or field named" matread(path, "nope", Matrix{Float64})
end
