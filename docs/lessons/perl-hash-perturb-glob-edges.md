# Perl hash perturbation and CODE `"the glob"` edges

- **Status:** semantics-note (both backends; affects oracles/tests)
- **Area:** GLOB / CODE protosub linking · outrefs · inrefs cross-backend tests
- **Date:** 2026-08-07

## One-liner

Across loads (or backends) without a fixed hash seed, CODE→GLOB weak edges
such as `"the glob"` can attach to **different** addresses while totals stay
the same — so cross-run inrefs/outrefs multisets look “flaky.”

## Symptom / measurement

- Two loads of the same dump, same backend, same process: edge **set** can
  differ (hundreds of edges only in run A vs run B) while edge **count**
  matches.
- With `PERL_HASH_SEED` fixed and `PERL_PERTURB_KEYS=0` in a **new**
  interpreter, perl vs rust outref/inrefs multisets can match 100%.
- Cross-backend tests without a fixed-seed child falsely failed on GLOB weak
  counts.

## What was tried / observed

- Comparing rust vs perl `inrefs_*` on micro/self dumps without controlling
  hash seed → intermittent mismatches concentrated on **GLOB** weak/direct.
- Full outref scan to a single target sometimes agreed while aggregate slot
  counts disagreed across independent loads.

## Why it matters (root cause)

Perl’s hash key iteration order is randomized (seed + perturbation). Dump
load / protosub / glob linking walks structures whose order depends on that
iteration. Result: which CODE claims `"the glob"` (or similar) for a given
GLOB can differ across process starts even though structure is “the same.”

This is **not** unique to Rust; both backends inherit the effect when
building proxy graphs from the dump.

## Correct model / invariant

- For **parity oracles** across backends or process boundaries, spawn a child
  with:
  - `PERL_HASH_SEED=<fixed>`
  - `PERL_PERTURB_KEYS=0`
- Within one load, same-backend reverse rebuild of inrefs from outrefs should
  still be self-consistent (classic path).
- Prefer same-load reverse rebuild tests when hash noise would dominate.

## Do not treat as

- A CSR-only bug, or “rust is wrong,” without re-checking under a fixed seed.

## Related tests / code

- `t/99-hotpath-lazy.t` (fixed-seed child for perl vs rust inrefs)
- `t/93-perl-rust-diff.t` (GLOB outrefs multiset; same process)
- Devel::MAT dump load / CODE–GLOB fixup paths
