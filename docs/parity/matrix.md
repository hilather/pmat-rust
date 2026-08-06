# Feature parity matrix (scaffold)

Oracle: **Devel-MAT 0.54**. Status values: `pass` | `fail` | `wip` | `n/a` | `blocked`.

Comparison modes: `exact` · `structured_exact` · `semantic_multiset` (only when 0.54 order is unspecified).

| ID | Surface | Mode | Perl | Rust | Notes |
|----|---------|------|------|------|-------|
| PAR-000 | Original `t/*.t` unit suite on forced Perl | exact | pass | n/a | Gating: oracle path |
| PAR-001 | Backend selection `PMAT_BACKEND` | exact | pass | pass | perl/rust/auto; no silent mis-attribute |
| PAR-010 | Load dump format minor ≤6 | structured_exact | pass | pass | heap count, roots; micro fixture |
| PAR-011 | Reject unknown format / bad magic | exact | pass | pass | forced-rust croak on bad magic; t/95 |
| PAR-020 | Type counts (`count`) | structured_exact | pass | pass | batch `type_counts` on Rust; file-type vs reclass |
| PAR-021 | Summary after load | exact | pass | pass | one-shot non-TTY micro |
| PAR-030 | Outrefs sample | semantic_multiset | pass | pass | GLOB outrefs_direct multiset exact; REF ≥90%; immortals retained |
| PAR-031 | Inrefs sample / reverse edges | semantic_multiset | pass | pass | reverse CSR; every sampled forward edge has reverse |
| PAR-040 | Identify | exact | pass | pass | full SV materialization; walk_graph under forced rust; t/10 + t/95 |
| PAR-050 | Sizes structure/owned | structured_exact | pass | pass | structure/owned match oracle; t/10 + t/95 |
| PAR-060 | Reachability | structured_exact | pass | pass | defstash + known CVs; t/10 + t/95 |
| PAR-070 | Blessed-hash SV proxy identity | exact | pass | pass | one proxy per addr/ObjectId; durable tool_* keys |
| PAR-080 | Plugin discovery / tool_* | exact | pass | pass | available_tools + load_tool under forced rust |
| PAR-090 | Companion scripts (6 exes) | exact | pass | pass | pmat -q summary/count + companions invoked under rust |
| PAR-100 | Malformed dumps | exact | pass | pass | truncated dump errors under forced rust; t/95 |
| PAR-110 | Persistent `.pmat.idx` | exact | n/a | wip | later phase (deferred) |
| PAR-120 | TTY goldens | exact | pass | pass | non-TTY one-shot gated; Cmd::Terminal present; t/95 |

## Backend test rule

A test marked **Rust pass** must run with `PMAT_BACKEND=rust` and must fail if
Rust is unavailable or panics. Auto-fallback to Perl is never a Rust pass.

## Update policy

Update this matrix when a row’s status changes. Keep `docs/agent-bundle/` as the
human workplan source; this file is the machine-oriented gate table.
