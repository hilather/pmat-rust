# Committed baseline bench JSON

JSON snapshots from `./bench/run-bench --json=…` used as the durable “before”
numbers summarized in [`docs/performance.md`](../../docs/performance.md).

## When to refresh

Per root [`AGENTS.md`](../../../AGENTS.md): **every performance-affecting commit**
must update measured evidence. At minimum refresh `docs/performance.md` tables
from a new run; refresh files in this directory when:

- shipping a major OPT milestone or release, or
- the prior baseline is no longer comparable (harness phases, fixture tiers, or default backend changed).

Suggested naming: keep `perl-cold-*`, `rust-cold-*`, `rust-warm-idx-*` for the
canonical small+medium set, or add dated copies if you need side-by-side history.

```bash
./bench/run-bench --size=small,medium --json=bench/results/baseline/rust-cold-small-medium.json
# then edit docs/performance.md summary tables to match
```
