# Performance baselines & optimization backlog

Source of truth for load/query performance work after feature parity (v0.55.0,
default `PMAT_BACKEND=rust`). Every OPT item needs before/after measurements;
parity suites must stay green under `PMAT_BACKEND=perl` and `PMAT_BACKEND=rust`.

**Agent rule:** performance is the primary product goal. **Update this file on
every performance-affecting commit** (tables + OPT checkboxes + honest
residuals), and re-run `./bench/run-bench` (at least `--size=small`). Process
details: root [`AGENTS.md`](https://github.com/hilather/pmat-rust/blob/main/AGENTS.md).

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

### v0.57.0 full-suite re-bench (rust cold, 2026-08-07)

`./bench/run-bench --size=small,medium` after OPT-02/09/10 + classic inrefs residual:

| Tier | Load (s) | Inrefs (s) | Count (s) | Total (s) | Peak RSS (MB) |
|------|----------|------------|-----------|-----------|---------------|
| small | **0.227** | 1.46 | 0.25 | 4.14 | 269 |
| medium | **1.025** | 5.62 | 1.17 | 17.7 | 1372 |

Load remains ~**6.5×** vs pre-OPT-01 rust cold. Full-suite inrefs/count still pay after materialize (suite order); interactive open path (summary/default count without full heap) is documented under “After open-path…” below.

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
- [x] **OPT-02** — Default `count` without full proxy walk (dense `object_at` + CODE pad reclass; option modes still walk)
- [ ] **OPT-03** — Inrefs CSR first-use (residual: dense reverse graph lacks some 0.54 edges e.g. CODE "the glob"; classic outref walk retained for oracle parity)
- [ ] **OPT-04** — Sizes / reachability / find on native model (partial: owned_size memoization shipped; native CSR still open)
- [ ] **OPT-05** — Identify / outrefs / show on batch edges (materialize walk set only)
- [ ] **OPT-06** — Cheap / stub proxies for graph-only walks
- [ ] **OPT-07** — Reduce dual-residency memory (core + Perl)
- [ ] **OPT-08** — Hash outref O(K²) path
- [x] **OPT-09** — Index size gate (default skip fat `.pmat.idx` under 64 MiB unless `PMAT_IDX=1`)
- [x] **OPT-10** — Top-K / largest without full Fibonacci heap; correct cached `owned_size`
- [ ] **OPT-11** — Huge / production scaling gates
- [x] **OPT-12** — Measure & guard regressions

### After open-path / count / index policy (inrefs classic — OPT-03 residual)

Measured forced-rust, `PMAT_IDX=0` (post CSR-inrefs pullback for oracle parity):

| Path | Before (medium) | After (medium) | After (small) | Materialize |
|------|-----------------|----------------|---------------|-------------|
| **summary** | ~10 s | **~0 s** | **~0 s** | roots only (~1.5k / 666k) |
| **default count** | ~2 s (after full heap) | **~1.2–1.4 s** | **~0.3 s** | **no full heap** (~1.5k) |
| **inrefs init** | ~7 s | **~14–17 s** | **~3 s** | **full heap** (classic outref walk) |

**Inrefs residual (OPT-03):** pure CSR reverse was attempted but rejected — dense strengths are structural (not 0.54 weak array/CODE `"the glob"`), and scalar `inrefs_*` overcounted without outrefs re-filter. Shipped path is the classic `foreach heap + outrefs` walk for oracle parity (`t/10tool-inrefs.t`, `t/99-hotpath-lazy.t`). Re-enable CSR only after the dense edge builder emits the full 0.54 strong/weak set.

**Index policy:** default uses/writes `.pmat.idx` only when dump size ≥ **64 MiB** (`PMAT_IDX_MIN_BYTES`). `PMAT_IDX=1|force|always` always on; `PMAT_IDX=0` off.

### After OPT-10 (`largest --owned` + correct owned_size)

| Metric | Before | After | Notes |
|--------|--------|-------|-------|
| Full-heap `owned_size` pass (small, 143k) | 23.6 s | **~2.9 s** | children-cache + leaf path; **0 mismatches** vs classic |
| Full-heap `owned_size` pass (medium, 666k) | **>630 s** (killed) | **~13 s** | ≫40× |
| `largest --owned` command (small) | ~117 s | much lower precompute; tree still costs | top-K is O(N·K) |
| `largest --owned` command (medium) | (owned pass alone >630 s) | precompute ~13 s + tree | residual tree/`heap()` |

**Correctness:** `owned_size` is always a classic `%seen` walk (≡ `sum size over owned_set`). Child-sum DP is **unsafe** because exclusive-child edges form a digraph (same refcnt==1 SV claimed from multiple parents, e.g. GLOB→CODE + protosub GLOB→CODE).  

**Residual:** full `heap()` materialize + display-tree `owned_set` expansion.

### OPT-01 — Lazy SV proxies on forced-Rust load  **[P0 — DONE]**

| | |
|--|--|
| **Problem** | `_load_rust` eagerly builds every proxy (`0 .. heap_count-1`) via `_rust_make_sv_full`. Dominates load. |
| **Change** | On load: roots, immortals, stack/mortal/context metadata only. `sv_at` / `rust_proxy_for_id` materialize one proxy per ObjectId and cache in `heap` + `_proxy_by_id`. `heap()` fully materializes (0.54 semantics). Per-SV fixup on first materialize; full protosub index on `heap()`. |
| **Files** | `lib/Devel/MAT/Dumpfile.pm`; `t/97-lazy-proxies.t` |
| **Accept** | Identity stable (one proxy per id); forced-rust parity suites green; `heap()` still complete |

### OPT-02 — Count without full proxy walk  **[DONE]**

| | |
|--|--|
| **Problem** | `Tool::Count` walked full `heap()` for default count. |
| **Change** | Default mode: dense `object_at` scan + CODE pad→PAD/PADLIST/PADNAMES reclass + YES/NO→BOOL; bytes from core sizes. Options still heap-walk. |
| **Files** | `lib/Devel/MAT/Tool/Count.pm`; `t/99-hotpath-lazy.t` |
| **Accept** | Default table matches 0.54 type reclassification (PAD/BOOL/…); option modes unchanged |

### OPT-03 — Batch / native inrefs build  **[OPEN — residual]**

| | |
|--|--|
| **Problem** | Inrefs first-use walks every proxy outref (materialize + full scan). Medium ~14–17 s after classic restore. |
| **Attempt** | CSR reverse candidates alone miss 0.54 edges (e.g. CODE `"the glob"`) and structural strength ≠ weak array/CODE globs; pure-CSR lost weak edges and broke scalar/list count parity. |
| **Current** | Classic outref walk retained for oracle parity (`t/10tool-inrefs.t`, `t/99-hotpath-lazy.t` reverse rebuild + fixed-hash-seed perl oracle). |
| **Next** | Extend dense edge builder to emit full 0.54 strong/weak set, then re-enable CSR reverse + outrefs re-filter. |

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

### OPT-09 — Index cost model (size gate)  **[DONE — threshold; not mmap]**

| | |
|--|--|
| **Problem** | Fat full-snapshot `.pmat.idx` can be slower/heavier than re-parse on small/medium. |
| **Change** | Default: use/write index only if dump ≥ 64 MiB (`PMAT_IDX_MIN_BYTES`). Force with `PMAT_IDX=1`. |
| **Files** | `rust/pmat-core/src/index.rs`, `ffi.rs`; `t/99-hotpath-lazy.t` |
| **Residual** | Still full dense snapshot (no mmap); helps large dumps only |

### OPT-10 — Top-K / largest + faster correct owned_size  **[DONE]**

| | |
|--|--|
| **Problem** | `largest --owned` re-did expensive `outrefs_strong` on every walk; Fibonacci heap over all N for K≈5. |
| **Change** | Classic `%seen` `owned_size` (correct for multi-parent exclusive digraph); cache `_owned_children`; leaf fast-path; gen-counter seen; fixed top-K `_select_topk`. |
| **Files** | `lib/Devel/MAT/Tool/Sizes.pm`; `t/98-largest-owned.t` |
| **Accept** | Full-heap precompute matches classic sum for every SV; multi-parent claimants match; top-K matches full sort |

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
