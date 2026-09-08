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
            using PureMAT
        end,
        PureMAT.matopen(String),
        PureMAT.matsize(PureMAT.MatFile, String),
        PureMAT.matclass(PureMAT.MatFile, String),
        PureMAT.matread(PureMAT.MatFile, String, Type{Matrix{Float64}}),
        PureMAT.matread(PureMAT.MatFile, String, Type{Array{Float64, 3}}),
        PureMAT.matread(PureMAT.MatFile, String, Type{Matrix{Float32}}),
        PureMAT.matread(PureMAT.MatFile, String, Type{Matrix{Int32}}),
        PureMAT.matread(PureMAT.MatFile, String, Type{Matrix{UInt8}}),
        PureMAT.matread(PureMAT.MatFile, String, Type{Matrix{Bool}}),
        PureMAT.matread(PureMAT.MatFile, String, Type{Matrix{ComplexF64}}),
        PureMAT.matread(PureMAT.MatFile, String, Type{String}),
    )
end
