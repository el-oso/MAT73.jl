@testitem "MATLAB classes are reported from the attributes" setup = [Fixtures] begin
    using MAT73: MAT_DOUBLE, MAT_SINGLE, MAT_INT32, MAT_UINT8, MAT_LOGICAL, MAT_CHAR,
        MAT_CELL, MAT_STRUCT, MAT_UNSUPPORTED

    f = matopen(fixture("simple.mat"))
    @test matclass(f, "double") == MAT_DOUBLE
    @test matclass(f, "single") == MAT_SINGLE
    @test matclass(f, "int32") == MAT_INT32
    @test matclass(f, "uint8") == MAT_UINT8
    @test matclass(f, "logical") == MAT_LOGICAL

    @test matclass(matopen(fixture("char_unicode.mat")), "a") == MAT_CHAR
    @test matclass(matopen(fixture("cell.mat")), "cell") == MAT_CELL
    @test matclass(matopen(fixture("struct.mat")), "s") == MAT_STRUCT
    # Sparse and MATLAB objects are not the plain class their attribute names.
    @test matclass(matopen(fixture("sparse.mat")), "sparse_eye") == MAT_UNSUPPORTED
end

@testitem "logical arrays read as Bool" setup = [Fixtures] begin
    f = matopen(fixture("logical.mat"))
    for name in ("logical", "logical_mat")
        ref = oracle("logical.mat", name)
        refa = ref isa AbstractArray ? ref : fill(ref, 1, 1)
        got = matread(f, name, Matrix{Bool})
        @test got == refa
        @test eltype(got) === Bool
    end
end

@testitem "a logical is not silently a UInt8, and vice versa" setup = [Fixtures] begin
    f = matopen(fixture("logical.mat"))
    @test_throws "logical array" matread(f, "logical_mat", Matrix{UInt8})
    g = matopen(fixture("simple.mat"))
    @test_throws "not a MATLAB logical" matread(g, "uint8", Matrix{Bool})
end

@testitem "complex arrays read as Complex" setup = [Fixtures] begin
    ref = oracle("complex.mat", "imaginary")
    got = matread(matopen(fixture("complex.mat")), "imaginary", Matrix{ComplexF64})
    @test got == ref
end

@testitem "char arrays read as String" setup = [Fixtures] begin
    f = matopen(fixture("char_unicode.mat"))
    for name in ("a", "b", "c", "d")
        @test matread(f, name, String) == oracle("char_unicode.mat", name)
    end
    # A char matrix is several rows, so it has no single string form.
    @test_throws "not a 1xN char array" matread(f, "e", String)
end

@testitem "char matrices read elementwise" setup = [Fixtures] begin
    # MAT.jl decodes a char matrix to one String per row, combining surrogate pairs. This
    # package returns the UTF-16 code units MATLAB actually stores, so the oracle's rows are
    # re-split into code units to compare the two.
    function fromrows(rows::Vector{String})
        units = [transcode(UInt16, r) for r in rows]
        out = Matrix{Char}(undef, length(units), maximum(length, units))
        for i in eachindex(units), j in eachindex(units[i])
            out[i, j] = Char(units[i][j])
        end
        return out
    end

    f = matopen(fixture("char_unicode.mat"))
    for name in ("e", "g")
        got = matread(f, name, Matrix{Char})
        @test got == fromrows(oracle("char_unicode.mat", name))
    end

    # `f` is a 3x8x2 char array: rank carries through unchanged.
    volume = matread(f, "f", Array{Char, 3})
    @test size(volume) == (3, 8, 2)
    @test volume[1, 1, 1] == fromrows(vec(oracle("char_unicode.mat", "f")))[1, 1]

    @test_throws "not a MATLAB char array" matread(matopen(fixture("simple.mat")), "double", Matrix{Char})
    @test_throws "not a MATLAB char array" matread(matopen(fixture("simple.mat")), "double", String)
end

@testitem "an empty array keeps its shape" setup = [Fixtures] begin
    # array.mat's `empty` is stored as a uint64 vector of dimensions plus MATLAB_empty,
    # not as zero elements of the array's own type.
    f = matopen(fixture("array.mat"))
    ref = oracle("array.mat", "empty")
    @test matsize(f, "empty") == collect(size(ref))
    got = matread(f, "empty", Matrix{Float64})
    @test size(got) == size(ref)
    @test isempty(got)
end
