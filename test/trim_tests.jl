# `--trim=safe` compatibility is a requirement of this package, so it is checked here rather
# than only in a manual build. TrimCheck runs the same reachability analysis as the compiler.
#
# It runs the verifier pass a real build runs, over one root signature at a time, so a failure
# here is a failure of the build too. What it does not cover is linking and startup, which is
# why `juliac/build.jl` exists alongside it.

@testitem "entry points are trim-safe" tags = [:trim] begin
    using TrimCheck
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
