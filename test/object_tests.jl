# MATLAB objects. A classdef variable holds no data of its own — only indices into tables in
# `#subsystem#` — so these check that the indirection resolves to the same values MAT.jl gets.

@testsnippet Objects begin
    using MAT73
    import MAT
    const OBJFILE = joinpath(@__DIR__, "fixtures", "v7.3", "user_defined_classdefs.mat")

    "MAT.jl wraps an object's properties in a MatlabOpaque; unwrap to a plain Dict."
    opaque(name) = MAT.matread(OBJFILE)[name]
end

@testitem "object class names resolve through the subsystem" setup = [Objects] begin
    f = matopen(OBJFILE)
    @test matobjectclass(f, "obj_with_vals") == "TestClasses.BasicClass"
    @test matobjectclass(f, "obj_no_vals") == "TestClasses.BasicClass"
    @test matobjectclass(f, "obj_with_default_val") == "TestClasses.DefaultClass"
    # A variable that is not an object has no class name.
    g = matopen(joinpath(@__DIR__, "fixtures", "v7.3", "simple.mat"))
    @test matobjectclass(g, "double") == ""
end

@testitem "object properties are listed and read" setup = [Objects] begin
    f = matopen(OBJFILE)
    @test sort(matkeys(f, "obj_with_vals")) == ["a", "b", "c"]

    ref = opaque("obj_with_vals")
    # a is set; b and c are left empty by the constructor.
    @test matread(f, "obj_with_vals/a", Matrix{Float64}) == fill(ref["a"], 1, 1)
    @test isempty(matread(f, "obj_with_vals/b", Matrix{Float64}))
    @test isempty(matread(f, "obj_with_vals/c", Matrix{Float64}))
end

@testitem "an unknown property names itself" setup = [Objects] begin
    f = matopen(OBJFILE)
    @test_throws "no property named" matread(f, "obj_with_vals/nope", Matrix{Float64})
end

@testitem "matclass still reports objects as unsupported" setup = [Objects] begin
    # matclass answers the plain-array question, and an object is not a plain array; its class
    # name comes from matobjectclass instead.
    using MAT73: MAT_UNSUPPORTED
    f = matopen(OBJFILE)
    @test matclass(f, "obj_with_vals") == MAT_UNSUPPORTED
end
