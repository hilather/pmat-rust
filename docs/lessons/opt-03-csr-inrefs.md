# OPT-03: pure-CSR inrefs build

- **Status:** failed / residual (classic outref walk shipped)
- **Area:** OPT-03 · `Tool::Inrefs` · dense reverse CSR / `inrefs_batch`
- **Date:** 2026-08-07

## One-liner

Seeding tool inrefs from dense CSR reverse edges alone was much faster but
**wrong** for 0.54: strengths and some edges do not match proxy `outrefs`, and
scalar context overcounted.

## Symptom / measurement

- Medium first-use: CSR path ~1.5 s vs classic ~7–15 s (attractive).
- Self-dump / fixture: thousands of GLOBs wrong on weak/direct; scalar
  `inrefs_strong` ≫ list on many SVs under CSR.
- Skeptic/oracle: `t/10tool-inrefs.t` and cross-backend samples failed.

## What was tried

1. Build reverse index from `inrefs_batch` / CSR reverse table (structural
   Strong/Weak tags from the dense edge builder).
2. Skip full `foreach heap + outrefs` materialize for first-use.
3. Rely on list-path outrefs re-filter for display only; count path used raw
   CSR slots (`just_count`).

## Why it failed (root cause)

1. **CSR strength ≠ 0.54 outref strength.** Dense edges are structural. 0.54
   marks many edges **weak** (array elements, CODE `"the glob"`, etc.). CSR
   often tags them Strong → edges land only in the strong slot → list
   `inrefs_strong` re-filters them away and **weak never sees the sources**.
2. **Missing edges.** CODE `"the glob"` (and similar) may be absent from CSR
   while present on Perl `outrefs`.
3. **Scalar vs list.** `just_count` counted CSR slot addresses without the
   outrefs re-filter; list path re-filters → systematic scalar overcount.

## Correct model / invariant

- Shipped path: **classic** `foreach $df->heap` + `$sv->outrefs("NO_DESC")`
  to bucket by 0.54 strength, then list context re-filters via `outrefs`.
- Scalar and list `inrefs_*` must agree under the classic path.
- Forced-rust strong/weak/direct must match forced-perl on a deterministic
  oracle (fixed hash seed child — see
  [perl-hash-perturb-glob-edges](perl-hash-perturb-glob-edges.md)).

## Do not retry until

- Dense edge builder emits the **full 0.54 strong/weak set** (including CODE
  glob, array element weaknesses, egv rules), **and**
- Scalar path re-filters or counts the same multiset as list, **and**
- `t/10tool-inrefs.t` + `t/99-hotpath-lazy.t` inrefs section stay green.

## Partial edge-strength fixes (2026-08-11)

Shipped for owned ranking / identify candidates (still not full OPT-03):

- ARRAY body elems: **weak** when `array_flags & 0x01` (Av not REAL / is_unreal);
  **strong** when REAL (matches `SV::ARRAY::_outrefs`).
- CODE ptrs: STASH weak; GLOB weak unless CVGV_RC; OUTSIDE weak if WEAKOUTSIDE;
  PADLIST/CONSTVAL strong; body consts/gvs strong or indirect under ithreads;
  padnames/pads indirect when PADLIST present.

Remaining CSR≠0.54 edges still cause absolute owned score drift on some STASHes;
top-K **sets** are tested against classic.

## Related tests / code

- `lib/Devel/MAT/Tool/Inrefs.pm` (classic walk + residual note)
- `t/10tool-inrefs.t`, `t/99-hotpath-lazy.t`
- `docs/performance.md` OPT-03 residual
