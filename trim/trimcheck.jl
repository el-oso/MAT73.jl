# Static half of the trim gate: run the `--trim=safe` verifier over every entry point.
#
# It has its own environment: TrimCheck pins the `Compiler` stdlib, which the test
# environment has no reason to carry.
#
# Run as: julia --project=trim trim/trimcheck.jl
#
# TrimCheck runs the same verifier pass a real build runs, so a failure here is a failure of
# the build too. It neither links nor runs, which is what `juliac/build.jl` adds.

using Test
using TrimCheck


@testset "entry points are trim-safe" begin
    @validate(
        init = begin
            using MAT73
            # The macro expands to ordinary typed reads, so a function that uses it must
            # verify like any other. This is the root that proves it.
            #
            # `@eval` because the whole init block is expanded before `using` runs, so the
            # macro is not known yet at that point.
            @eval function loadfields(f::MAT73.MatFile)
                return MAT73.@matload f begin
                    a::Matrix{Float64}
                    n::Int64
                    label::String
                    gain = "cfg/gain"::Float64
                end
            end
        end,
        Main.loadfields(MAT73.MatFile),
        MAT73.matopen(String),
        MAT73.matread(String, String, Type{Matrix{Float64}}),
        MAT73.matread(String, String, Type{String}),
        MAT73.matsize(MAT73.MatFile, String),
        MAT73.matclass(MAT73.MatFile, String),
        MAT73.matread(MAT73.MatFile, String, Type{Matrix{Float64}}),
        MAT73.matread(MAT73.MatFile, String, Type{Array{Float64, 3}}),
        MAT73.matread(MAT73.MatFile, String, Type{Matrix{Float32}}),
        MAT73.matread(MAT73.MatFile, String, Type{Matrix{Int32}}),
        MAT73.matread(MAT73.MatFile, String, Type{Matrix{UInt8}}),
        MAT73.matread(MAT73.MatFile, String, Type{Matrix{Bool}}),
        MAT73.matread(MAT73.MatFile, String, Type{Matrix{ComplexF64}}),
        MAT73.matread(MAT73.MatFile, String, Type{String}),
        MAT73.matread(MAT73.MatFile, String, Type{Matrix{MAT73.DateTime}}),
        MAT73.matread(MAT73.MatFile, String, Type{Matrix{String}}),
        MAT73.matread(MAT73.MatFile, MAT73.MatRef, Type{Matrix{String}}),
        MAT73.matread(
            MAT73.MatFile, String,
            Type{NamedTuple{(:a, :b), Tuple{Vector{Float64}, Vector{String}}}},
        ),
        MAT73.matread(MAT73.MatFile, String, Type{Matrix{MAT73.MatRef}}),
        MAT73.matread(MAT73.MatFile, MAT73.MatRef, Type{Matrix{Float64}}),
        MAT73.matread(MAT73.MatFile, MAT73.MatRef, Type{String}),
        MAT73.matclass(MAT73.MatFile, MAT73.MatRef),
        MAT73.matsize(MAT73.MatFile, MAT73.MatRef),
        MAT73.matkeys(MAT73.MatFile, String),
        MAT73.matobjectclass(MAT73.MatFile, String),
        Base.push!(MAT73.MatWriter, String, Matrix{Float64}),
        Base.push!(MAT73.MatWriter, String, Matrix{Bool}),
        MAT73.matwrite(String, MAT73.MatWriter),
    )
end
