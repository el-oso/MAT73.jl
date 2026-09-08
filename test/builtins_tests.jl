# MATLAB's own classes: a date, and text held as a `string`. Neither keeps its value where a
# plain array does, so each is checked against MAT.jl, which applies the same rule.

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

@testitem "a string reads as a String" setup = [Fixtures] begin
    import MAT

    path = fixture("struct_table_datetime.mat")
    f = matopen(path)
    ref = MAT.matread(path)["s"]["testTable"]

    # The string columns of the table: the customer names, and the free-text comments.
    columns = matread(f, "s/testTable/data", Matrix{MAT73.MatRef})
    for (i, name) in ((2, :Customer), (5, :Comment))
        @test matobjectclass(f, columns[i]) == "string"
        got = matread(f, columns[i], Matrix{String})
        @test eltype(got) === String
        @test vec(got) == ref[name]
    end
end

@testitem "the short read gives a String too" setup = [Fixtures] begin
    import MAT

    path = fixture("struct_table_datetime.mat")
    f = matopen(path)
    columns = matread(f, "s/testTable/data", Matrix{MAT73.MatRef})
    got = matread(f, columns[2])
    @test eltype(got) === String
    @test vec(got) == MAT.matread(path)["s"]["testTable"][:Customer]
end

@testitem "asking for a String array from something else is an error" setup = [Fixtures] begin
    f = matopen(fixture("simple.mat"))
    @test_throws "not a MATLAB string" matread(f, "double", Matrix{String})
end

@testitem "an object inside an object is recognized without a note" setup = [Fixtures] begin
    # MATLAB writes MATLAB_object_decode only at the top level. Inside #subsystem# the tag
    # that starts the index array is the only mark left, and it is enough.
    f = matopen(fixture("struct_table_datetime.mat"))
    columns = matread(f, "s/testTable/data", Matrix{MAT73.MatRef})
    @test matobjectclass(f, columns[3]) == "datetime"
    @test matclass(f, columns[3]) == MAT73.MAT_UNSUPPORTED
    # A plain numeric column keeps its own class.
    @test matobjectclass(f, columns[1]) == ""
    @test matclass(f, columns[1]) == MAT73.MAT_DOUBLE
end
