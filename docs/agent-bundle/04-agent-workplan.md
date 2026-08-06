# Agent workplan

## Phase 0 - Freeze the oracle
- Pin the exact 0.54 source tree and checksums.
- Build it in a reproducible environment.
- Run all original tests.
- Capture command output, help text, and transcripts.
- Record the executables and module inventory.

## Phase 1 - Build the contract
- Generate a machine-readable feature matrix.
- Inventory all commands, options, selectors, and tool plugins.
- Enumerate all object types and format branches.
- Add a test case for every unknown behavior.

## Phase 2 - Create fixtures and differential oracle
- Build small, medium, large, and malformed dumps.
- Capture goldens from 0.54.
- Implement a differential runner that compares oracle vs candidate.
- Collect stdout, stderr, exit code, and structured API data.

## Phase 3 - Measure performance
- Benchmark load time and peak memory.
- Profile parsing, graph construction, reverse edges, and top queries.
- Keep raw benchmark artifacts and machine metadata.

## Phase 4 - Fix legacy hot paths
- Replace keys-plus-linear-lookup hash traversal.
- Replace full-heap top-K structures with fixed-size selection.
- Buffer parser reads more efficiently.
- Preserve all visible behavior while reducing complexity.

## Phase 5 - Rust parser and dense model
- Implement a lossless Rust parser.
- Create dense ObjectId-based storage.
- Build forward and reverse edge tables.
- Persist a versioned index sidecar.

## Phase 6 - Native queries
- Move counts, find, inrefs, outrefs, identify, sizes, and summaries into Rust.
- Batch results across the FFI boundary.
- Keep hot loops entirely in native code.

## Phase 7 - Perl compatibility bridge
- Preserve blessed-hash SV proxies.
- Preserve object identity.
- Preserve plugin state and lazy tool loading.
- Preserve scalar/list context behavior.

## Phase 8 - Command integration
- Route built-in commands through native queries.
- Keep existing help, formatting, pagination, and interactive behavior.
- Verify companion executables.

## Phase 9 - Hardening and release
- Run parity, malformed-input, and plugin tests.
- Verify persistent index invalidation and corruption handling.
- Promote Rust only when all parity rows pass.

## Mandatory TODO behavior

- Every unknown behavior becomes a characterization test.
- Every optimization is backed by measured evidence.
- Every output change is reviewed explicitly.
- Every Rust panic is contained before FFI crossing.
- Every release gate is binary: pass or fail.
