# Master instructions for the implementation agent

You are implementing a modernization of Devel::MAT / PMAT version 0.54.

**Also obey the standing repo rules in [`AGENTS.md`](../../AGENTS.md)** (performance first, docs + regression tests + benchmarks every commit). This file is the parity/modernization brief; `AGENTS.md` is process SoT.

## Objective

Reduce dump-loading time, query latency, and memory use by introducing a Rust parser, dense object model, graph/index engine, and coarse-grained query layer.

Performance is the primary product goal after (and only after) oracle-correct behavior.

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

1. Select one or more feature-parity IDs (or OPT IDs from `docs/performance.md`).
2. Inspect the exact 0.54 source and POD.
3. Create or identify a minimal fixture.
4. Capture the 0.54 behavior.
5. **Add a characterization, differential, or regression test first** (must fail without the fix / catch a wrong fast path).
6. Implement the smallest internal change (prefer large-dump wall time and RSS).
7. Run the original tests.
8. Run the complete affected parity suite (forced perl **and** forced rust).
9. **Run the relevant benchmark** (`./bench/run-bench`, at least `--size=small`).
10. **Update `docs/performance.md`** (tables, OPT checkboxes, residuals) and any architecture/parity docs in the **same** change.
11. Report changed files, evidence, performance, risks, and rollback.

Do not commit without steps 5, 9, and 10 when the change can affect runtime behavior.

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
- Every performance-affecting commit updates benchmarks + `docs/performance.md` (see root `AGENTS.md`).
- Never ship an optimization without a regression test that guards oracle parity or the lazy/materialize invariant.
- Every failed OPT, wrong approach, or newly understood Perl/Rust semantic is logged under `docs/lessons/` (index + optional detail).

## Release gate

Do not declare the work complete or enable the Rust backend by default until every parity row passes, there are no skipped parity tests, all original tests pass unchanged, all executables pass, the third-party plugin fixture passes unchanged, malformed and cross-format fixture tests pass, TTY and non-TTY transcripts pass, performance results are documented, and no known compatibility gap remains.
