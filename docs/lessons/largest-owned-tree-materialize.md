# largest --owned: deep owned tree forces materialize

- **Status:** mitigated (native nested tree shipped; classic path residual)
- **Area:** OPT-10 / `Tool::Sizes` · `list_largest_svs` nested `owned_set`
- **Date:** 2026-08-11 (updated same day: CSR nested tree)

## One-liner

Classic nested `owned_set` on large STASHes materializes most of the heap
(~60–70 s medium). **Shipped fix:** expand nested “of which” from dense CSR
exclusive descendants in Rust (`pmat_owned_largest_tree`); materialize only
printed nodes (~0.7 s medium, +~12 proxies).

## Symptom / measurement (historical)

- Native `pmat_owned_sizes` on small: **~0.03 s**.
- With classic nested tree counts 5/3/2: medium **~60–70 s**, mat ≈ full heap.
- Top-level only: medium **~0.9 s**.

## Shipped mitigation (after)

- Parallel `owned_sizes` (`PMAT_OWNED_THREADS`); `pmat_owned_topk` /
  `pmat_owned_largest_tree` FFI; Sizes uses tree path for default
  `largest --owned` (including 5 3 2).
- **Formal harness** medium `largest_owned` **0.803 s** (was 72.2 s OPT-10);
  small **0.076 s** (was 11.36 s). See
  `bench/results/baseline/largest-owned-native-tree.json` and
  `bench/results/baseline/largest-owned-native-tree.md`.
- Nested mat stays sparse (printed nodes only); “of which” present without
  `PMAT_OWNED_FULL`.
- `PMAT_OWNED_FULL=1` restores classic full-heap `owned_set` tree.

## What was tried (and rejected as default)

- Seed `tool_sizes_owned` from native scores then full classic tree walk.
- Candidate re-rank with classic `owned_size` on top-64 (huge STASH walks).

## Residual

- Nested ranking uses CSR exclusive digraph (multi-parent diamonds; not
  always identical to classic `owned_set` membership when edges residual).
- Exact top-5 set on regenerated micro dumps still may swap tail ranks.
