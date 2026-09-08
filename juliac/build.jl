# Build `entry.jl` with `juliac --trim=safe` and check the binary against the same read done
# in Julia. This is the authoritative trim gate: TrimCheck analyses stock Base and does not
# model finalizers, while `juliac` raises `max_args` and roots every reachable one, so the two
# can disagree in both directions.
#
# Run as: julia --project=juliac juliac/build.jl

using PureMAT

const HERE = @__DIR__
const ROOT = dirname(HERE)
const ENTRY = joinpath(HERE, "entry.jl")
const BINARY = joinpath(HERE, "matsum")
const DRIVER = joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac.jl")

const FIXTURE = joinpath(ROOT, "test", "fixtures", "v7.3", "array.mat")
const VARIABLE = "a2x2"

function build()
    isfile(DRIVER) || error("no juliac driver at $DRIVER; it ships with Julia 1.12 and later")
    isfile(BINARY) && rm(BINARY)
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$HERE $DRIVER
           --output-exe $BINARY --experimental --trim=safe $ENTRY`
    @info "building" cmd
    # stdin is redirected because the juliaup launcher can panic reading a non-blocking
    # stdin after the build has already succeeded, which looks like a build failure.
    run(pipeline(cmd; stdin = devnull))
    isfile(BINARY) || error("juliac reported success but produced no binary")
    return BINARY
end

"What the binary should print, computed through the ordinary Julia path."
function reference()
    a = matread(matopen(FIXTURE), VARIABLE, Matrix{Float64})
    s = 0.0
    for i in eachindex(a)
        s += a[i]
    end
    return string("n=", length(a), " sum=", s)
end

function main()
    build()
    want = reference()
    got = strip(read(`$BINARY $FIXTURE $VARIABLE`, String))
    if got != want
        @error "trimmed binary disagrees with the Julia path" got want
        exit(1)
    end
    @info "trim gate passed" got
    return nothing
end

main()
