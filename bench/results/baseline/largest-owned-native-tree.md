# largest / largest_owned: formal harness after native CSR tree

Forced `PMAT_BACKEND=rust`, `PMAT_IDX=0`, tree counts **5 3 2**.
Fixtures: `fixtures/small-mixed-n5000.pmat`, `fixtures/medium-mixed-n25000.pmat`.

Harness (this run):

```bash
PMAT_BACKEND=rust PMAT_IDX=0 \
  ./bench/run-bench --size=small,medium \
  --phases=load,largest,largest_owned \
  --largest-counts=5,3,2 \
  --json=bench/results/baseline/largest-owned-native-tree.json
```

JSON: [`bench/results/baseline/largest-owned-native-tree.json`](https://github.com/hilather/pmat-rust/blob/main/bench/results/baseline/largest-owned-native-tree.json)

## Results (this run)

| Tier | Phase | Seconds | RSS Δ |
|------|-------|---------|-------|
| small (143k) | load | 0.224 s | ~107 MiB |
| small | largest | 0.314 s | ~6.5 MiB |
| small | **largest_owned** | **0.076 s** | ~8.3 MiB |
| medium (666k) | load | 1.063 s | ~480 MiB |
| medium | largest | 1.872 s | ~26 MiB |
| medium | **largest_owned** | **0.803 s** | ~53 MiB |

## Vs prior formal baselines (same fixtures / counts)

| Tier | Phase | v0.56.0 | OPT-10 (`largest-after-0.57`) | **Native tree (this)** | vs OPT-10 |
|------|-------|---------|-------------------------------|------------------------|-----------|
| small | largest_owned | 134 s | 11.36 s | **0.076 s** | **~149×** |
| medium | largest_owned | 843 s | 72.2 s | **0.803 s** | **~90×** |

Prior table: `bench/results/baseline/largest-topk-v056-vs-current.md`.
Prior JSON: `bench/results/largest-after-0.57.json`.

## Notes

- `largest_owned` is the shipped `run_command("largest --owned 5 3 2")` path
  (parallel dense scores + CSR nested exclusive-descendant top-K; materialize
  printed nodes only). Not `PMAT_OWNED_FULL`.
- Ad-hoc single-shot timings on the same host were ~0.67–0.70 s medium; formal
  phase here is **0.803 s** (includes harness overhead / warm process state after
  `largest` on the same load).
- Do not treat parallel `owned_sizes` micro-splits as harness phases; those are
  separate core-only measurements.
