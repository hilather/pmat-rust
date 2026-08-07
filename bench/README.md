# Devel::MAT benchmark & fixture suite

Tools to measure and regression-test `pmat` / `Devel::MAT` performance on dumps
ranging from **fast iteration sizes** (seconds) up to **multi-gigabyte** dumps
comparable to **~17 GiB production process** heap files.

## Prerequisites

```bash
# From the repo root, with deps available (see local/ if you used a local lib):
export PERL5LIB="$PWD/local/lib/perl5${PERL5LIB:+:$PERL5LIB}"

perl Build.PL
./Build
# Optional: run upstream unit tests
./Build test
```

`Devel::MAT::Dumper` is required to **generate** realistic dumps. Loading and
benchmarking an existing `.pmat` only needs a built `Devel::MAT`.

## Quick start (fast iteration)

```bash
# Build micro + small fixtures (default gen set)
./bench/gen-fixture

# Run the default benchmark tier (small)
./bench/run-bench

# Save JSON for before/after comparisons
./bench/run-bench --json=bench/results/baseline.json
```

Default bench size is **`small`** (~5k mixed graph nodes, on the order of tens
of MB / a few hundred thousand SVs). It is meant to be re-run often while
optimizing.

## Size tiers

| Tier    | Method    | What it is | Typical use |
|---------|-----------|------------|-------------|
| `micro` | Dumper    | ~200 mixed nodes | Unit tests (`t/90-*.t`) |
| `small` | Dumper    | ~5k nodes | **Default** bench iteration |
| `medium`| Dumper    | ~25k nodes | Deeper local runs |
| `large` | Dumper    | ~100k nodes | Stress graph tools |
| `xlarge`| Dumper    | ~400k nodes | Heavy machine only |
| `huge`  | Synthetic bulk | Streaming dump; default **256 MiB**, max **17 GiB** | Load/I/O & SV-table scaling without a 17 GiB live process |

Aliases for `--size` / `PMAT_BENCH_SIZE`:

- `default` / `quick` → `small`
- `test` → `micro`
- `all` → every tier
- `17G` / `2G` / `512M` → `huge` with that target size

```bash
./bench/gen-fixture --list
./bench/gen-fixture --size=medium
./bench/run-bench --size=medium,large

# Full 17 GiB synthetic dump (needs ~17 GiB free disk; generator RSS stays low)
./bench/gen-fixture --size=17G
./bench/run-bench --size=17G
```

### Production dumps

Point the harness at a real dump (including multi-GB captures from large
processes):

```bash
./bench/run-bench --file=/path/to/prod.pmat --json=bench/results/prod.json
```

## What is measured

| Phase | Why it matters |
|-------|----------------|
| `load` | `Devel::MAT->load` + fixup (often the first wall-clock cliff) |
| `inrefs` | Back-reference index; prerequisite for identify & many analyses |
| `heap_walk` | Raw `outrefs(NO_DESC)` scan over every SV |
| `count` | Type histogram |
| `sizes_struct` | Structural size over the heap |
| `sizes_owned` | Owned size (**sampled**; enable with `--owned`) |
| `reachability` | Root reachability classification |
| `identify` | Referrer walk on a sample SV |

RSS start/end/peak (Linux `/proc`) is recorded when available.

## Fixture layout

```
fixtures/
  micro-mixed-n200.pmat
  micro-mixed-n200.pmat.meta.json
  small-mixed-n5000.pmat
  ...
  huge-256M.pmat          # synthetic bulk
```

Override location with `--dir` or `PMAT_FIXTURES`. Fixtures are gitignored;
regenerate with `./bench/gen-fixture`.

### Shapes (Dumper method)

- `mixed` (default) — nested hashes/arrays; realistic connectivity  
- `wide` — one large array of scalars  
- `deep` — linked list of refs  
- `pv` — large string bodies  

```bash
./bench/gen-fixture --size=small --shape=wide --force
```

### Synthetic bulk (`huge`)

Streams a valid PMAT 0.6 file: immortals + one root `ARRAY` of `SCALAR` PVs.
Generator memory stays small; on-disk size tracks `--target-bytes` / `17G`.

Use this for **load-path and heap-table scaling**. Prefer real Dumper tiers or
`--file` production dumps for full tool realism (stashes, code, HEKs, …).

## Tests

```bash
# Full suite including fixture + CLI smokes (needs Dumper + built blib)
./Build test

# Or just the new tests:
prove -Iblib/lib -Iblib/arch -Ilocal/lib/perl5 -Ibench/lib t/90-fixture-load.t t/91-bench-cli.t
```

`t/90-fixture-load.t` always builds a **micro** fixture (and a 1 MiB synthetic)
in a temp dir — suitable for CI. It does **not** build large tiers.

## Environment variables

| Variable | Meaning |
|----------|---------|
| `PMAT_BENCH_SIZE` | Default `--size` for gen/run |
| `PMAT_FIXTURES` | Fixtures directory |
| `PMAT_HUGE_BYTES` | Integer byte override for `huge` |

## Suggested optimization loop

1. `./bench/run-bench --json=bench/results/before.json`
2. Change code, `./Build`
3. `./bench/run-bench --json=bench/results/after.json`
4. Compare `phases.load.seconds`, `phases.inrefs.seconds`, RSS peak
5. Periodically promote: `--size=medium` → `large` → `--file=prod.pmat` / `--size=17G`

Committed baseline table and prioritized OPT backlog:
[docs/performance.md](https://github.com/hilather/pmat-rust/blob/main/docs/performance.md).
