# Master instructions for the implementation agent

You are implementing a modernization of Devel::MAT / PMAT version 0.54.

## Objective

Reduce dump-loading time, query latency, and memory use by introducing a Rust parser, dense object model, graph/index engine, and coarse-grained query layer.

## Non-negotiable requirement

The result must have complete feature parity with Devel::MAT 0.54.

Version 0.54 is the frozen behavioral oracle. You may change internal algorithms and data layouts, but you may not change externally observable behavior.

## Feature parity includes

- dump format support through minor version 6
- accepted and rejected input behavior
- all executables
- every command, option, alias, selector, and help screen
- interactive and one-shot behavior
- pagination and cancellation
- stdout, stderr, exit status, and TTY formatting
- every public Perl class and method
- scalar/list context behavior
- object identity
- all SV types and fields
- roots, stack, contexts, symbols, and packages
- strong, weak, indirect, and inferred references
- reachability and identify paths
- size calculations
- plugin discovery and lifecycle
- blessed-hash SV proxies and persistent tool_* keys
- installed modules, POD, scripts, and assets

## Architectural direction

Use a Rust core and retain the Perl compatibility and command layer until complete parity has been demonstrated.

The Rust core should contain:

- a safe PMAT format parser
- a dense ObjectId-based model
- binary-safe string storage
- lossless IV, UV, and NV representation
- address-to-ID lookup
- contiguous forward and reverse reference graphs
- reference strength and description metadata
- roots, stack, context, symbol, and package tables
- a versioned persistent .pmat.idx format
- coarse-grained query APIs
- a stable C ABI and XS bridge

## Compatibility model

Rust-backed SVs exposed to Perl must remain blessed hash references in the legacy class hierarchy.

Each materialized ObjectId must have one strongly cached Perl proxy for the lifetime of the dump. This preserves object identity and arbitrary plugin tool_* keys.

Do not eagerly materialize proxies. Built-in commands should execute native batch queries and materialize only displayed results. The public heap() API may materialize all proxies when explicitly called.

## Backend modes

Implement:

- `PMAT_BACKEND=perl`
- `PMAT_BACKEND=rust`
- `PMAT_BACKEND=auto`

All compatibility tests must run with both forced backends. Automatic fallback does not count as a Rust pass.

## Implementation loop

For every task:

1. Select one or more feature-parity IDs.
2. Inspect the exact 0.54 source and POD.
3. Create or identify a minimal fixture.
4. Capture the 0.54 behavior.
5. Add a characterization or differential test.
6. Implement the smallest internal change.
7. Run the original tests.
8. Run the complete affected parity suite.
9. Run forced Perl and forced Rust comparisons.
10. Run the relevant benchmark.
11. Update the parity matrix and architecture docs.
12. Report changed files, evidence, performance, risks, and rollback.

## Rules

- Never claim parity from the original test suite alone.
- Never silently correct legacy semantics.
- Never normalize away substantive differences.
- Never perform one FFI call per object or edge in a hot loop.
- Never expose dump addresses as native pointers.
- Never assume strings are valid UTF-8.
- Never reduce 10-byte NV values to f64 without preserving raw data.
- Never trust an index without validating its schema and source digest.
- Never modify the source .pmat file.
- Never allow a Rust panic across the FFI boundary.
- Never delete the Perl implementation before the complete parity gate.
- Never make the Rust backend the default while a parity row is failing.
- Every unknown behavior requires a characterization test.
- Every output change requires explicit review.
- Every optimization requires before-and-after measurements.

## Release gate

Do not declare the work complete or enable the Rust backend by default until every parity row passes, there are no skipped parity tests, all original tests pass unchanged, all executables pass, the third-party plugin fixture passes unchanged, malformed and cross-format fixture tests pass, TTY and non-TTY transcripts pass, performance results are documented, and no known compatibility gap remains.
