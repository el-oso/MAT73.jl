# libhdf5 writes a different shape of the same format than MATLAB does: superblock version 2,
# version-2 object headers and compact groups made of link messages. This package's own writer
# targets that shape, so reading it is a prerequisite for round-tripping.

@testitem "superblock 2, v2 object headers and link-message groups" setup = [Fixtures] begin
    path = joinpath(@__DIR__, "fixtures", "matjl", "written_by_matjl.mat")
    f = matopen(path)
    expected = h5_matopen(keys, path)
    @test sort(keys(f)) == sort(collect(expected))

    ref(name) = h5_matopen(io -> h5_read(io, name), path)

    @test matread(f, "a2x2", Matrix{Float64}) == ref("a2x2")
    @test matread(f, "big", Matrix{Float64}) == ref("big")
    @test matread(f, "i32", Matrix{Int32}) == ref("i32")
    @test matread(f, "flags", Matrix{Bool}) == ref("flags")
    @test matread(f, "label", String) == ref("label")
end

@testitem "MATLAB classes survive the other header shape" setup = [Fixtures] begin
    using MAT73: MAT_DOUBLE, MAT_INT32, MAT_LOGICAL, MAT_CHAR
    f = matopen(joinpath(@__DIR__, "fixtures", "matjl", "written_by_matjl.mat"))
    @test matclass(f, "a2x2") == MAT_DOUBLE
    @test matclass(f, "i32") == MAT_INT32
    @test matclass(f, "flags") == MAT_LOGICAL
    @test matclass(f, "label") == MAT_CHAR
end
