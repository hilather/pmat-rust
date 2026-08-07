# Performance baselines & optimization backlog

Source of truth for load/query performance work after feature parity (v0.55.0,
default `PMAT_BACKEND=rust`). Every OPT item needs before/after measurements;
parity suites must stay green under `PMAT_BACKEND=perl` and `PMAT_BACKEND=rust`.

Harness: [`bench/README.md`](https://github.com/hilather/pmat-rust/blob/main/bench/README.md)
(`./bench/run-bench --json=…`). Raw JSON may live under `bench/results/`
(often gitignored); **this document** holds the committed summary.

## Baseline (2026-08-06, local host)

Machine: Linux, Perl 5.38, Devel-MAT 0.54 tree, fixtures from `./bench/gen-fixture`.

| Fixture | Heap SVs | Bytes | Path | Load (s) | Inrefs (s) | Count (s) | Total (s) | Peak RSS (MB) |
|---------|----------|-------|------|----------|------------|-----------|-----------|---------------|
| small-mixed-n5000 | 143 319 | 11.0 MiB | **perl cold** | 1.90 | 1.02 | 0.31 | 4.20 | 170 |
| small-mixed-n5000 | 143 319 | 11.0 MiB | **rust cold** | 1.47 | 1.07 | 0.31 | 3.85 | 269 |
| small-mixed-n5000 | 143 319 | 11.0 MiB | **rust warm+idx** | 1.65 | 1.06 | 0.32 | 3.30† | 261 |
| medium-mixed-n25000 | 665 769 | 49.3 MiB | **perl cold** | 8.91 | 4.85 | 1.53 | 20.2 | 822 |
| medium-mixed-n25000 | 665 769 | 49.3 MiB | **rust cold** | 6.81 | 5.05 | 1.55 | 18.4 | 1371 |
| medium-mixed-n25000 | 665 769 | 49.3 MiB | **rust warm+idx** | 7.57 | 5.00 | 1.56 | 15.5† | 1330 |

† Warm runs used a reduced phase set (no reachability/sizes); total not
directly comparable to cold full suite.

### Core-only load (no Dumpfile proxy materialization)

| Fixture | Core cold (`PMAT_IDX=0`) | Core + valid `.pmat.idx` |
|---------|--------------------------|---------------------------|
| small | **0.13 s** | 0.30 s |
| medium | **0.63 s** | 1.31 s |

### Takeaways

1. **Rust parse is already fast.** Core-only medium load ≈ **0.6 s** vs Dumpfile
   load ≈ **6.8 s** → ~**90% of forced-Rust wall time is Perl proxy materialization**,
   not parsing.
2. **Full path vs Perl is only ~1.2–1.3×** on load; tool phases (count, inrefs,
   sizes, reachability, identify) are **parity-bound** — they walk blessed
   proxies the same way as 0.54.
3. **Fat index can lose to cold re-parse** on these sizes (index load 1.3 s vs
   parse 0.6 s). Index remains useful for larger dumps / repeated opens; do not
   treat “warm always faster” as a given until OPT-09.
4. **RSS is higher under Rust Dumpfile** when tools force full `heap()` (dual
   residency: dense core + full Perl heap map). After OPT-01, **load itself**
   materializes only roots/contexts (~1–2k proxies); RSS during identify-only
   workflows drops accordingly. Full-heap tools still pay materialize-on-first-`heap()`.

Committed baseline JSON: `bench/results/baseline/*-small-medium.json`.
Ephemeral re-runs may also appear as gitignored `bench/results/*.json`.

### After OPT-01 (lazy proxies) — rust cold load

| Tier | Baseline load (s) | After load (s) | Speedup |
|------|-------------------|----------------|---------|
| small | 1.47 | **0.22** | **~6.5×** |
| medium | 6.81 | **1.02** | **~6.7×** |

Core-only vs Dumpfile after load (roots only, not full `heap()`):

| Tier | Core cold | Dumpfile lazy load | Proxies at load |
|------|-----------|--------------------|-----------------|
| small | 0.12 s | 0.22 s | ~1.3k / 143k |
| medium | 0.63 s | 0.95 s | ~1.5k / 666k |

Note: full-suite wall time still includes inrefs/count/… which call `heap()` and
re-materialize everything; OPT-02–05 target those phases.

---

## Optimization backlog (todos)

Priority is **impact on user-visible load / interactive tools**, not rewrite
volume. Checkboxes: `[x]` done in-tree, `[ ]` still open.

- [x] **OPT-01** — Lazy SV proxies on forced-Rust load (on-demand `sv_at` / `rust_proxy_for_id`; `heap()` full materialize; one proxy per ObjectId)
- [ ] **OPT-02** — Count without full proxy walk (default mode from `type_counts`; preserve PAD/BOOL reclass)
- [ ] **OPT-03** — Batch / native inrefs build from CSR / `inrefs_batch`
- [ ] **OPT-04** — Sizes / reachability / find on native model
- [ ] **OPT-05** — Identify / outrefs / show on batch edges (materialize walk set only)
- [ ] **OPT-06** — Cheap / stub proxies for graph-only walks
- [ ] **OPT-07** — Reduce dual-residency memory (core + Perl)
- [ ] **OPT-08** — Hash outref O(K²) path
- [ ] **OPT-09** — Index cost model & mmap / selective hydrate
- [ ] **OPT-10** — Top-K / largest without full heap structure
- [ ] **OPT-11** — Huge / production scaling gates
- [x] **OPT-12** — Measure & guard regressions (baseline committed; re-bench after OPT-01)

### OPT-01 — Lazy SV proxies on forced-Rust load  **[P0 — DONE]**

| | |
|--|--|
| **Problem** | `_load_rust` eagerly builds every proxy (`0 .. heap_count-1`) via `_rust_make_sv_full`. Dominates load. |
| **Change** | On load: roots, immortals, stack/mortal/context metadata only. `sv_at` / `rust_proxy_for_id` materialize one proxy per ObjectId and cache in `heap` + `_proxy_by_id`. `heap()` fully materializes (0.54 semantics). Per-SV fixup on first materialize; full protosub index on `heap()`. |
| **Files** | `lib/Devel/MAT/Dumpfile.pm`; `t/97-lazy-proxies.t` |
| **Accept** | Identity stable (one proxy per id); forced-rust parity suites green; `heap()` still complete |

### OPT-02 — Count without full proxy walk  **[P0]**

| | |
|--|--|
| **Problem** | `Tool::Count` still `foreach $self->df->heap` after calling `type_counts` (batch result unused for display). |
| **Change** | Default `count` (no blessed/scalars/struct/owned): render from `rust_core->type_counts` (+ native sizes if needed). Fall back to heap walk for options that need proxy fields. |
| **Files** | `lib/Devel/MAT/Tool/Count.pm`; optional native size histogram FFI |
| **Target** | Count phase ≪ 1.5 s on medium when default mode |
| **Accept** | Default table matches 0.54 type reclassification (PAD/BOOL/…); option modes unchanged |

### OPT-03 — Batch / native inrefs build  **[P1]**

| | |
|--|--|
| **Problem** | Inrefs phase ~5 s on medium — same as Perl; reverse edges already exist in Rust CSR. |
| **Change** | When Rust core present, seed tool inrefs from `inrefs_batch` (or bulk reverse table export) instead of scanning every outref via proxies. |
| **Files** | `Tool/Inrefs.pm`, Core XS FFI if bulk export missing |
| **Target** | Inrefs first-use pause near CSR scan cost, not full proxy graph walk |
| **Accept** | Inref edges + strengths + descriptions match oracle on fixtures |

### OPT-04 — Sizes / reachability / find on native model  **[P1]**

| | |
|--|--|
| **Problem** | Full-heap tools re-walk proxies; structural/owned size and reachability do not use dense graph. |
| **Change** | Native structural size + reachability labels over CSR; Find filters by type/addr without materializing all SVs. Owned size may stay sampled or lazy. |
| **Files** | `Tool/Sizes.pm`, `Tool/Reachability.pm`, `Tool/Find.pm`, pmat-core FFI |
| **Target** | Tool phases improve once OPT-01 avoids forced materialize-on-heap |
| **Accept** | Structural sizes and reachability classes match 0.54 on fixture set |

### OPT-05 — Identify / outrefs / show on batch edges  **[P1]**

| | |
|--|--|
| **Problem** | Referrer walks still go through Perl outref/inref methods after materialization. |
| **Change** | Prefer `outrefs_batch` / `inrefs_batch` for edge lists; materialize only SVs that appear in the walk / display set. |
| **Files** | `Tool/Identify.pm`, `Tool/Outrefs.pm`, `Tool/Show.pm`, Graph helpers |
| **Target** | Interactive identify on huge dumps without full heap materialize |
| **Accept** | Identify paths and strength/desc match oracle |

### OPT-06 — Cheap / stub proxies for graph-only walks  **[P2]**

| | |
|--|--|
| **Problem** | Even lazy materialize may pay full `_rust_make_sv_full` when a tool only needs type/addr/size/edges. |
| **Change** | Lightweight proxy or dual-mode accessor: header fields from FFI, payload filled on demand. |
| **Depends** | OPT-01 |
| **Accept** | No identity split; plugins that set `tool_*` keys still work |

### OPT-07 — Reduce dual-residency memory  **[P2]**

| | |
|--|--|
| **Problem** | Peak RSS ~1.4 GiB rust vs ~0.8 GiB perl on medium after full materialize. |
| **Change** | After OPT-01: avoid retaining duplicate string bodies / array elems in both core and Perl when not needed; optional “release payload” mode; consider not pinning full core strings in Perl HV until accessed. |
| **Target** | RSS for identify-only session closer to core + sparse proxies |
| **Accept** | No use-after-free; load/query correctness unchanged |

### OPT-08 — Hash outref O(K²) path (legacy + bridge)  **[P2]**

| | |
|--|--|
| **Problem** | Large HASH SVs: linear `value_at` per key during outref walks (agent-bundle bottleneck #4). |
| **Change** | Key→index map or native hash outrefs from core; ensure Rust HASH payload already enables O(K) edge emit. |
| **Files** | Perl `SV.pm` hash paths and/or rust payload edge builder |
| **Accept** | Large-hash fixture outrefs match; bench on wide-hash shape |

### OPT-09 — Index cost model & mmap / selective hydrate  **[P2]**

| | |
|--|--|
| **Problem** | Full dense snapshot index can be **slower** than re-parse on small/medium dumps. |
| **Change** | Skip index write/read below size threshold; or mmap + partial hydrate; document when `PMAT_IDX` helps. |
| **Files** | `rust/pmat-core/src/index.rs`, `ffi.rs` |
| **Accept** | Medium cold load not regressed by default index policy; large dumps improve |

### OPT-10 — Top-K / largest without full heap structure  **[P3]**

| | |
|--|--|
| **Problem** | `largest` / heavy heap selection for small K (agent-bundle #6). |
| **Change** | Fixed-size selection over native sizes; avoid full Perl sort of all SVs. |
| **Accept** | Same top-K set (stable tie-break documented if needed) |

### OPT-11 — Huge / production scaling gates  **[P3]**

| | |
|--|--|
| **Problem** | Baselines only cover small/medium; production dumps multi-GB. |
| **Change** | Formalize `large` / `huge` / `--file=prod.pmat` baseline table; CI optional job or manual release gate. |
| **Accept** | Documented numbers for ≥1 GiB dump load (core + lazy Dumpfile) |

### OPT-12 — Measure & guard regressions  **[ongoing]**

| | |
|--|--|
| **Change** | Keep this file’s summary table updated; optional `t/` micro bench smoke; never flip a tool to native-only without differential oracle. |
| **Loop** | `./bench/run-bench --size=small,medium --json=bench/results/after.json` → update table → parity `prove` both backends |

---

## Suggested execution order

```
OPT-01 lazy proxies     ──┬──► OPT-02 count native display
                          ├──► OPT-03 inrefs from CSR
                          ├──► OPT-05 identify/outrefs batch
                          └──► OPT-06 stub proxies ──► OPT-07 RSS

OPT-04 sizes/reach/find (can start after OPT-01 skeleton)

OPT-08 hash O(K)        (independent; good with large-hash fixtures)
OPT-09 index policy     (independent; measure first)
OPT-10 largest          (after native sizes)
OPT-11 huge baselines   (anytime; before claiming multi-GB wins)
OPT-12 measure          (every PR)
```

## Gates (any OPT)

1. `PMAT_BACKEND=perl` full suite green (oracle unchanged).
2. `PMAT_BACKEND=rust` parity suites green (`t/90`–`t/96`, matrix).
3. Before/after load + relevant phase times on **small + medium** recorded here.
4. No silent fallback: forced rust still fails hard on load error.
5. Docs: update this file + architecture note if load semantics change (lazy heap).

## Non-goals (for now)

- Pure-Perl parser micro-opts (Rust path is default).
- Changing public CLI output for speed without explicit review.
- Claiming multi-GB wins without OPT-11 numbers.
