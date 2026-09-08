# Entry point for the trimmed-binary gate. `juliac` includes this file into `Main`, so
# `@main` has to sit at top level: a module wrapper is only allowed for a package entry.
#
# `Core.stdout` rather than `println(x)`, because `Base.stdout` is an abstract global and is
# not statically resolvable.

using MAT73

function (@main)(args::Vector{String})::Cint
    out = Core.stdout
    if length(args) < 2
        println(out, "usage: matsum <file.mat> <variable>")
        return Cint(2)
    end
    f = matopen(args[1])
    a = matread(f, args[2], Matrix{Float64})
    s = 0.0
    for i in eachindex(a)
        s += a[i]
    end
    println(out, "n=", length(a), " sum=", s)
    return Cint(0)
end
