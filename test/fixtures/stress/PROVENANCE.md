# Stress fixtures

Derived from `../v7.3/partial.mat` with `h5repack`, which keeps superblock version 0,
version-1 object headers and the 512-byte MATLAB user block while producing storage MATLAB
itself does not emit here:

    h5repack --low=0 --high=1 -u ub.bin -b 512 \
             -l /var1:CHUNK=7x13 -f /var1:SHUF -f /var1:GZIP=3 partial.mat s_h1.mat

The `--low`/`--high` bounds are load-bearing: without them `h5repack` writes superblock
version 2 with version-2 object headers, which is outside the MAT v7.3 subset.

`s_h1.mat` exercises a shuffle+deflate pipeline, partial edge chunks in both dimensions, and
a multi-node chunk B-tree. Values were checked equal to the original through MAT.jl.
