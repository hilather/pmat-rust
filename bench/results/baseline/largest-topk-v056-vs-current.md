# largest / largest_owned: v0.56.0 vs current (OPT-10)

Forced `PMAT_BACKEND=rust`, `PMAT_IDX=0`, tree counts **5 3 2**.
Fixtures: `fixtures/small-mixed-n5000.pmat`, `fixtures/medium-mixed-n25000.pmat`.

| Tier | Phase | v0.56.0 | Current | Speedup |
|------|-------|---------|---------|---------|
| small | largest | 3.130 s | 0.307 s | ~10× |
| small | largest_owned | 133.959 s | 11.358 s | ~12× |
| medium | largest | 14.256 s | 1.542 s | ~9× |
| medium | largest_owned | 842.540 s | 72.2 s | ~12× |

Before: worktree at tag `v0.56.0` (Fibonacci heap + uncached owned walks).
After: OPT-10 `_select_topk` + owned children cache / precompute.

Harness: `./bench/run-bench --phases=load,largest,largest_owned`
