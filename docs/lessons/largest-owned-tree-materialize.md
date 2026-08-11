# largest --owned: deep owned tree forces materialize

- **Status:** residual (default native path is top-level only)
- **Area:** OPT-10 / `Tool::Sizes` · `list_largest_svs` nested `owned_set`
- **Date:** 2026-08-11

## One-liner

Even after dense owned precompute + top-K root selection, expanding the
**nested** `owned_set` display tree for large STASHes materializes most of the
heap and re-introduces multi-minute pauses.

## Symptom / measurement

- Native `pmat_owned_sizes` on small: **~0.03 s**.
- With nested tree counts 5/3/2: medium still **~60–70 s**, mat ≈ full heap.
- Top-level only (`list_largest_svs` with single K): medium **~0.9 s**, mat ≈ load roots.

## What was tried

- Seed `tool_sizes_owned` from native scores then run full tree walk.
- Candidate re-rank with classic `owned_size` on top-64 (still walked huge exclusive sets).

## Why it is expensive

Top owned SVs are often defstash / large packages. `owned_set` for those nodes
is a huge fraction of the heap; each exclusive child is materialized via
`outrefs_strong`.

## Correct default under rust native path

- Precompute owned scores in Rust (`Dump::owned_sizes` with 0.54-aligned CSR
  strong exclusive kids); materialize only top-K roots; print **top-level**
  list (no nested 3/2 tree).
- Exact native==classic score on controlled exclusive roots; micro top-K needs
  useful overlap (≥3/5), not exact set — CSR residual can swap tail ranks on
  regenerated mixed dumps (CI EL8). See `t/100-oom-hotpath.t`.
- `PMAT_OWNED_FULL=1` restores classic full-heap path (deep tree + full
  materialize).

## Do not retry until

- Stub proxies (OPT-06) or native owned_set expansion without full SV payloads,
  **or** an explicit UX for “expand this node” without pre-expanding all trees.
