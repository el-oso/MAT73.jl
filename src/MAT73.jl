"""
    MAT73

Read and write MATLAB `.mat` files of version 7.3. This package uses only Julia code. It does
not use the HDF5 C library. It also works inside a small compiled program.

You tell `matread` which type you expect. It does not guess. The type of a variable comes from
the file, and a function that could return any type would not build into a small program.

```julia
f = matopen("data.mat")
keys(f)                              # the names of the variables
matsize(f, "A")                      # the size, as MATLAB gives it
A = matread(f, "A", Matrix{Float64}) # checked against the file
```
"""
module MAT73

using Mmap
using ChunkCodecLibZlib: ZlibDecodeOptions
using ChunkCodecLibZlib.ChunkCodecCore: try_decode!

export matopen, matread, matsize, matclass, matkeys, matobjectclass, MatClass, MatRef,
    matwrite, MatWriter, @matload

include("lookup3.jl")
include("hdf5.jl")
include("chunked.jl")
include("mcos.jl")
include("read.jl")
include("macro.jl")
include("convenience.jl")
include("write.jl")

end # module MAT73
