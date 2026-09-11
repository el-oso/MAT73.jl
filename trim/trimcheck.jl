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
            # The same block given a path rather than an open file.
            @eval function loadfrompath(path::String)
                return MAT73.@matload path begin
                    a::Matrix{Float64}
                    label::String
                end
            end
            # The same block starting at a mark rather than at the top of the file.
            @eval function loadbelow(f::MAT73.MatFile, r::MAT73.MatRef)
                return MAT73.@matload f, r begin
                    nfield = "nfield"::Float64
                    xf = "wd/xf"::Matrix{Float64}
                    tag = "tag"::String
                end
            end
        end,
        Main.loadfields(MAT73.MatFile),
        Main.loadfrompath(String),
        Main.loadbelow(MAT73.MatFile, MAT73.MatRef),
        MAT73.matref(MAT73.MatFile, MAT73.MatRef, String),
        MAT73.matread(MAT73.MatFile, MAT73.MatRef, String, Type{Float64}),
        MAT73.matread(MAT73.MatFile, MAT73.MatRef, String, Type{Matrix{Float64}}),
        MAT73.matread(MAT73.MatFile, MAT73.MatRef, String, Type{String}),
        MAT73.matread(MAT73.MatFile, MAT73.MatRef, String, Type{Matrix{MAT73.MatRef}}),
        MAT73.matread(MAT73.MatFile, MAT73.MatRef, String, Type{Matrix{MAT73.DateTime}}),
        MAT73.matread(MAT73.MatFile, MAT73.MatRef, String, Type{Matrix{String}}),
        MAT73.matread(MAT73.MatFile, MAT73.MatRef, String, Type{Array{Char, 2}}),
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
        Base.push!(MAT73.MatWriter, String, Float64),
        Base.push!(MAT73.MatWriter, String, String),
        # A struct and a cell, each holding the other, so the nesting is verified too.
        Base.push!(
            MAT73.MatWriter, String,
            NamedTuple{
                (:gain, :label, :items),
                Tuple{Float64, String, Tuple{Float64, Matrix{Float64}}},
            },
        ),
        Base.push!(
            MAT73.MatWriter, String,
            Tuple{Matrix{Float64}, String, NamedTuple{(:n,), Tuple{Int64}}},
        ),
        MAT73.matwrite(String, MAT73.MatWriter),
    )
end
