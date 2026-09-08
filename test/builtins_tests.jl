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

@testitem "a table reads as a named tuple of columns" setup = [Fixtures] begin
    using Dates: DateTime
    import MAT
    import Tables

    path = fixture("struct_table_datetime.mat")
    f = matopen(path)
    ref = MAT.matread(path)["s"]["testTable"]

    t = matread(f, "s/testTable")
    @test t isa NamedTuple
    @test keys(t) == (:FlightNum, :Customer, :Date, :Rating, :Comment)
    for name in keys(t)
        @test t[name] == ref[name]
    end

    # A named tuple of vectors is a column table on its own.
    @test Tables.istable(t)
    @test Tables.columnnames(Tables.columns(t)) == keys(t)
end

@testitem "a table reads with the column types given" setup = [Fixtures] begin
    import MAT

    path = fixture("struct_table_datetime.mat")
    f = matopen(path)
    ref = MAT.matread(path)["s"]["testTable"]

    # A subset, in an order the file does not use.
    t = matread(
        f, "s/testTable",
        NamedTuple{(:Customer, :FlightNum), Tuple{Vector{String}, Vector{Float64}}},
    )
    @test t isa NamedTuple{(:Customer, :FlightNum), Tuple{Vector{String}, Vector{Float64}}}
    @test t.Customer == ref[:Customer]
    @test t.FlightNum == ref[:FlightNum]
end

@testitem "asking a table for a column it does not have is an error" setup = [Fixtures] begin
    f = matopen(fixture("struct_table_datetime.mat"))
    @test_throws "no column named \"Missing\"" matread(
        f, "s/testTable", NamedTuple{(:Missing,), Tuple{Vector{Float64}}}
    )
    @test_throws "is not a MATLAB table" matread(
        f, "s/testDatetime", NamedTuple{(:a,), Tuple{Vector{Float64}}}
    )
end

@testitem "a categorical reads as the text of each choice" setup = [Fixtures] begin
    import MAT

    path = fixture("struct_table_datetime.mat")
    f = matopen(path)
    columns = matread(f, "s/testTable/data", Matrix{MAT73.MatRef})
    @test matobjectclass(f, columns[4]) == "categorical"
    got = matread(f, columns[4], Matrix{String})
    @test vec(got) == MAT.matread(path)["s"]["testTable"][:Rating]
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
