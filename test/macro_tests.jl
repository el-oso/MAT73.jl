@testitem "the macro reads several variables at once" setup = [Fixtures] begin
    f = matopen(fixture("simple.mat"))
    v = @matload f begin
        double::Matrix{Float64}
        int32::Matrix{Int32}
        logical::Matrix{Bool}
    end
    @test v.double == fill(1.0, 1, 1)
    @test v.int32 == fill(Int32(1), 1, 1)
    @test v.logical == fill(true, 1, 1)
end

@testitem "a plain number type gives the single value" setup = [Fixtures] begin
    f = matopen(fixture("simple.mat"))
    v = @matload f begin
        double::Float64
        int16::Int16
    end
    @test v.double === 1.0
    @test v.int16 === Int16(1)
end

@testitem "the macro takes a path, under a name of your choice" setup = [Fixtures] begin
    f = matopen(fixture("struct.mat"))
    v = @matload f begin
        a = "s/a"::Float64
        b = "s/b"::Matrix{Float64}
    end
    @test v.a === 1.0
    @test size(v.b) == (1, 2)
end

@testitem "the macro reads object properties by path" setup = [Fixtures] begin
    f = matopen(fixture("dynamicprops.mat"))
    v = @matload f begin
        name = "obj/Name"::String
        data = "obj/DynamicData"::Float64
    end
    @test v.name == "Example"
    @test v.data === 42.0
end

@testitem "one line needs no begin block" setup = [Fixtures] begin
    f = matopen(fixture("array.mat"))
    v = @matload f a2x2::Matrix{Float64}
    @test v.a2x2 == [1.0 3.0; 4.0 2.0]
end

@testitem "the macro says what it accepts" setup = [Fixtures] begin
    @test_throws LoadError @eval @matload f (1 + 1)
    # Asking for a scalar when the variable holds many values is an error, not a silent pick.
    f = matopen(fixture("array.mat"))
    @test_throws "not 1" (@matload f a2x2::Float64)
end

@testitem "the result of the macro has a fixed type" setup = [Fixtures] begin
    # This is the whole point: the types are written into the code, so inference knows them.
    f = matopen(fixture("simple.mat"))
    g(h) = @matload h begin
        double::Float64
        int32::Matrix{Int32}
    end
    @test Base.return_types(g, (typeof(f),))[1] ===
        NamedTuple{(:double, :int32), Tuple{Float64, Matrix{Int32}}}
end

@testitem "the macro takes a path as well as an open file" setup = [Fixtures] begin
    path = fixture("simple.mat")
    f = matopen(path)
    fromfile = @matload path begin
        double::Matrix{Float64}
        int32::Matrix{Int32}
    end
    fromhandle = @matload f begin
        double::Matrix{Float64}
        int32::Matrix{Int32}
    end
    @test fromfile == fromhandle
end

@testitem "the macro evaluates its file argument once" setup = [Fixtures] begin
    # A path given as a call would otherwise be opened once for every variable listed.
    opens = Ref(0)
    counted() = (opens[] += 1; matopen(fixture("simple.mat")))
    v = @matload counted() begin
        double::Matrix{Float64}
        int32::Matrix{Int32}
        logical::Matrix{Bool}
    end
    @test opens[] == 1
    @test v.double == fill(1.0, 1, 1)
end
