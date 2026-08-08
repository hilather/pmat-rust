# Lessons log (failed attempts & hard-won semantics)

**Purpose:** keep agents from re-attempting dead ends or re-discovering
language/oracle quirks. Entries stay **light** in this index; drill into a
detail page when the failure needs repro steps, wrong invariants, or
language notes.

Standing process: root [`AGENTS.md`](../../AGENTS.md) § *Capture failed
attempts and hard-won semantics*.

## How to add an entry

1. **Index row** (this file) — one line: date, short title, status, link.
2. **Detail page** only if needed — `docs/lessons/<slug>.md` with repro,
   what was tried, why it failed, correct model, “do not retry until…”.
3. Cross-link residuals in `docs/performance.md` / parity docs when OPT-related.
4. Same commit as the pullback or discovery when possible.

### Index row template

```markdown
| YYYY-MM-DD | short title | failed / residual / semantics | [detail](slug.md) or — |
```

### Detail page template (`docs/lessons/<slug>.md`)

```markdown
# <Title>

- **Status:** failed | residual | semantics-note
- **Area:** OPT-NN / tool / rust-core / perl-bridge / …
- **Date:** YYYY-MM-DD

## One-liner
What we tried and the outcome (2–3 sentences max at the top of the page is fine;
the index already has the ultra-short form).

## Symptom / measurement
## What was tried
## Why it failed (root cause)
## Correct model / invariant
## Do not retry until
## Related tests / code
## Language notes (Perl / Rust)  # optional
```

Keep detail pages skimmable: bullets over essays. Put long dumps or logs in
scratch during investigation, not here.

---

## Index

| Date | Title | Kind | Detail |
|------|-------|------|--------|
| 2026-08-07 | OPT-03 pure-CSR inrefs (strengths + scalar count) | failed / residual | [opt-03-csr-inrefs](opt-03-csr-inrefs.md) |
| 2026-08-07 | Owned-size child-sum DP unsafe (multi-parent exclusive digraph) | failed approach | [owned-size-child-sum-dp](owned-size-child-sum-dp.md) |
| 2026-08-07 | CODE `"the glob"` / protosub edges depend on Perl hash perturbation | semantics | [perl-hash-perturb-glob-edges](perl-hash-perturb-glob-edges.md) |

---

## Quick scan (agents: read before retrying an OPT)

- **Inrefs:** do not ship pure CSR reverse for 0.54 parity; structural CSR ≠ weak array/CODE glob edges; scalar `inrefs_*` must match list after re-filter.
- **owned_size:** never sum child `owned_size` (diamond over-count); classic `%seen` walk only.
- **Cross-backend edge multisets:** fix `PERL_HASH_SEED` + `PERL_PERTURB_KEYS=0` in child processes when comparing perl vs rust outrefs/inrefs oracles.
