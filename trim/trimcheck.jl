# Static half of the trim gate: run the `--trim=safe` verifier over every entry point.
#
# It lives outside the package test environment because TrimCheck needs the `Compiler` stdlib
# that ships with Julia 1.12, and the package itself supports 1.10. Putting it in
# `test/Project.toml` makes the whole suite unresolvable on the LTS.
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
        end,
        MAT73.matopen(String),
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
        Base.push!(MAT73.MatWriter, String, Matrix{Float64}),
        Base.push!(MAT73.MatWriter, String, Matrix{Bool}),
        MAT73.matwrite(String, MAT73.MatWriter),
    )
end
