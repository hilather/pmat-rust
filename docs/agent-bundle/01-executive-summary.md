# Executive summary

Modernize Devel::MAT / PMAT version 0.54 by introducing a Rust parser, dense object model, graph/index engine, and coarse-grained query layer while preserving full feature parity with the 0.54 release.

The safest path is a hybrid architecture:

1. Keep the existing Perl command shell, plugin interface, and public API initially.
2. Move parsing, indexing, graph construction, and hot queries into Rust.
3. Preserve the legacy blessed-hash SV proxy behavior for compatibility.
4. Require the original 0.54 implementation to act as the behavioral oracle.
5. Promote the Rust backend only after every parity row passes.

A full rewrite of the frontend is optional and should not be the first milestone. The biggest wins come from data layout, indexing, and algorithmic fixes, not from language change alone.
