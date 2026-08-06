# Feature parity matrix (scaffold)

Oracle: **Devel-MAT 0.54**. Status values: `pass` | `fail` | `wip` | `n/a` | `blocked`.

Comparison modes: `exact` · `structured_exact` · `semantic_multiset` (only when 0.54 order is unspecified).

| ID | Surface | Mode | Perl | Rust | Notes |
|----|---------|------|------|------|-------|
| PAR-000 | Original `t/*.t` unit suite on forced Perl | exact | pass | n/a | Gating: oracle path |
| PAR-001 | Backend selection `PMAT_BACKEND` | exact | pass | pass | perl/rust/auto; no silent mis-attribute |
| PAR-010 | Load dump format minor ≤6 | structured_exact | pass | pass | heap count, roots; micro fixture |
| PAR-011 | Reject unknown format / bad magic | exact | pass | wip | |
| PAR-020 | Type counts (`count`) | structured_exact | pass | pass | batch `type_counts` on Rust; file-type vs reclass |
| PAR-021 | Summary after load | exact | pass | pass | one-shot non-TTY micro |
| PAR-030 | Outrefs sample | semantic_multiset | pass | pass | GLOB outrefs_direct multiset exact; REF ≥90%; immortals retained |
| PAR-031 | Inrefs sample / reverse edges | semantic_multiset | pass | pass | reverse CSR; every sampled forward edge has reverse |
| PAR-040 | Identify | exact | pass | wip | |
| PAR-050 | Sizes structure/owned | structured_exact | pass | wip | |
| PAR-060 | Reachability | structured_exact | pass | wip | |
| PAR-070 | Blessed-hash SV proxy identity | exact | pass | wip | one proxy per ObjectId |
| PAR-080 | Plugin discovery / tool_* | exact | pass | wip | |
| PAR-090 | Companion scripts (6 exes) | exact | pass | wip | out of this goal’s full gate |
| PAR-100 | Malformed dumps | exact | pass | wip | |
| PAR-110 | Persistent `.pmat.idx` | exact | n/a | wip | later phase |
| PAR-120 | TTY goldens | exact | pass | wip | non-TTY one-shot gated first |

## Backend test rule

A test marked **Rust pass** must run with `PMAT_BACKEND=rust` and must fail if
Rust is unavailable or panics. Auto-fallback to Perl is never a Rust pass.

## Update policy

Update this matrix when a row’s status changes. Keep `docs/agent-bundle/` as the
human workplan source; this file is the machine-oriented gate table.
