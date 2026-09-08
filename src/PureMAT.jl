"""
    PureMAT

Read MATLAB v7.3 (`-v7.3`) `.mat` files in pure Julia, with no HDF5 C library.

The reader covers the subset of HDF5 that MATLAB's own writer emits, and is written to
survive `juliac --trim=safe`, so it can be used from a trimmed binary. Callers state the
type they expect:

```julia
f = matopen("data.mat")
keys(f)                              # top-level variable names
matsize(f, "A")                      # MATLAB dimensions
A = matread(f, "A", Matrix{Float64}) # concrete return type, checked against the file
```
"""
module PureMAT

using Mmap
using ChunkCodecLibZlib: ZlibDecodeOptions
using ChunkCodecLibZlib.ChunkCodecCore: try_decode!

export matopen, matread, matsize, matclass, MatClass, matwrite, MatWriter

include("lookup3.jl")
include("hdf5.jl")
include("chunked.jl")
include("read.jl")
include("write.jl")

end # module PureMAT
