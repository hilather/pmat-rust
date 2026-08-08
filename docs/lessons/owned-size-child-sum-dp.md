# owned_size: child-sum DP is unsafe

- **Status:** failed approach (rejected; classic `%seen` walk shipped)
- **Area:** OPT-10 · `Tool::Sizes` · `owned_size` / `largest --owned`
- **Date:** 2026-08-07

## One-liner

Summing each exclusive child’s `owned_size` (tree DP) is **incorrect**:
exclusive strong edges form a **digraph**, not a tree — the same refcnt==1 SV
can be claimed from multiple parents.

## Symptom / measurement

- Child-sum DP over-counts diamonds (same exclusive child via GLOB→CODE and
  protosub GLOB→CODE, etc.).
- Full-heap precompute must match `sum size over owned_set` for every SV
  (including multi-parent claimants).

## What was tried

- Memoize `owned_size` as `size + sum(child->owned_size)` over
  `_owned_children` (refcnt==1, non-immortal, strong outrefs).
- Attractive: O(V+E) after one children pass if the graph were a forest.

## Why it failed (root cause)

Exclusive-child relation is **not a tree**. One SV can appear as a strong
outref with refcnt==1 from **multiple** parents. DP then counts that subtree
once per parent path → over-count vs classic `%seen` walk (0.54
`owned_set` / `owned_size` semantics).

## Correct model / invariant

- `owned_size` ≡ sum of `size` over `owned_set` (classic `%seen` DFS/stack).
- Cache **children lists** (`_owned_children`) to avoid repeating
  `outrefs_strong`; do **not** sum child `owned_size`.
- Leaf fast-path (no exclusive children) = just `size`.
- Full-heap precompute for `largest --owned`: prime children, then
  `owned_size` per SV.

## Do not retry until

- Proven that exclusive edges are a forest for the dump class under test
  (they are not, for real Perl heaps), **or**
- A different metric is explicitly defined and tested (not 0.54 owned size).

## Related tests / code

- `lib/Devel/MAT/Tool/Sizes.pm` (`owned_size`, `_owned_children`,
  `_precompute_owned_sizes`)
- `t/98-largest-owned.t`, `t/10tool-sizes.t`
- `docs/performance.md` OPT-10
