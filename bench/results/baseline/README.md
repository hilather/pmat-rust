# Committed performance baselines

Snapshot date: **2026-08-06** (pre OPT-01 lazy proxies).

These JSON files are the version-controlled reference for small + medium
tiers. Ephemeral re-runs under `bench/results/*.json` remain gitignored.

| File | Backend / mode |
|------|----------------|
| `perl-cold-small-medium.json` | `PMAT_BACKEND=perl`, cold load |
| `rust-cold-small-medium.json` | `PMAT_BACKEND=rust`, cold load |
| `rust-warm-idx-small-medium.json` | `PMAT_BACKEND=rust`, warm with `.pmat.idx` |

Human-readable summary and OPT backlog:
[docs/performance.md](https://github.com/hilather/pmat-rust/blob/main/docs/performance.md).

Regenerate (does not overwrite this tree unless you copy):

```bash
export PERL5LIB="$PWD/blib/lib:$PWD/blib/arch:$PWD/local/lib/perl5${PERL5LIB:+:$PERL5LIB}"
PMAT_BACKEND=perl  ./bench/run-bench --size=small,medium --json=bench/results/perl-cold-small-medium.json
PMAT_BACKEND=rust  ./bench/run-bench --size=small,medium --json=bench/results/rust-cold-small-medium.json
# warm: second pass with index present
PMAT_BACKEND=rust  ./bench/run-bench --size=small,medium --json=bench/results/rust-warm-idx-small-medium.json
```
