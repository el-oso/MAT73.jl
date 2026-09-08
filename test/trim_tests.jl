# `--trim=safe` compatibility is a requirement of this package, so it is checked here rather
# than only in a manual build. TrimCheck runs the same reachability analysis as the compiler.
#
# It is a dev-time heuristic, not the last word: it does not model finalizers, and it checks
# stock Base while `juliac` raises `max_args`. The authoritative gate is the real juliac build
# in CI. A failure here is still a real failure.

@testitem "entry points are trim-safe" tags = [:trim] begin
    using TrimCheck
    @validate(
        init = begin
            using PureMAT
        end,
        PureMAT.matopen(String),
        PureMAT.matsize(PureMAT.MatFile, String),
        PureMAT.matread(PureMAT.MatFile, String, Type{Matrix{Float64}}),
        PureMAT.matread(PureMAT.MatFile, String, Type{Array{Float64, 3}}),
        PureMAT.matread(PureMAT.MatFile, String, Type{Matrix{Float32}}),
        PureMAT.matread(PureMAT.MatFile, String, Type{Matrix{Int32}}),
        PureMAT.matread(PureMAT.MatFile, String, Type{Matrix{UInt8}}),
    )
end
