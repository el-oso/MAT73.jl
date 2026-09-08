# Fixtures written by MAT.jl

`written_by_matjl.mat` was produced by `MAT.matwrite`, which writes through libhdf5.

MATLAB writes superblock version 0, version-1 object headers and old-style groups. libhdf5
writes superblock version 2, version-2 object headers and compact groups made of link
messages, while keeping the 128-byte MATLAB banner in a 512-byte user block. Both shapes are
MATLAB-readable, and this package's own writer targets the second, so this fixture is the
independent example of it.
