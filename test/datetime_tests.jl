# MATLAB dates. The value is a count of milliseconds from 1 January 1970, so the check is
# against MAT.jl, which applies the same rule.

@testitem "a datetime reads as a DateTime" setup = [Fixtures] begin
    using Dates: DateTime
    import MAT

    path = fixture("struct_table_datetime.mat")
    f = matopen(path)
    ref = MAT.matread(path)["s"]

    for name in ("testDatetime", "testDatetimeComplex")
        got = matread(f, "s/" * name, Matrix{DateTime})
        @test eltype(got) === DateTime
        @test got == fill(ref[name], size(got))
    end
end

@testitem "the short read gives a DateTime too" setup = [Fixtures] begin
    using Dates: DateTime
    import MAT

    path = fixture("struct_table_datetime.mat")
    f = matopen(path)
    got = matread(f, "s/testDatetime")
    @test eltype(got) === DateTime
    @test got == fill(MAT.matread(path)["s"]["testDatetime"], size(got))
end

@testitem "asking for a DateTime from something else is an error" setup = [Fixtures] begin
    using Dates: DateTime
    f = matopen(fixture("simple.mat"))
    @test_throws "not a MATLAB datetime" matread(f, "double", Matrix{DateTime})
end

@testitem "a table still reads as a Dict of its properties" setup = [Fixtures] begin
    # No rule is known for a table, so it stays a set of named values.
    f = matopen(fixture("struct_table_datetime.mat"))
    @test matobjectclass(f, "s/testTable") == "table"
    t = matread(f, "s/testTable")
    @test t isa Dict{String, Any}
    @test "varnames" in keys(t)
end
