# Performance baselines & optimization backlog

Source of truth for load/query performance work after feature parity (v0.55.0,
default `PMAT_BACKEND=rust`). Every OPT item needs before/after measurements;
parity suites must stay green under `PMAT_BACKEND=perl` and `PMAT_BACKEND=rust`.

**Agent rule:** performance is the primary product goal. **Update this file on
every performance-affecting commit** (tables + OPT checkboxes + honest
residuals), and re-run `./bench/run-bench` (at least `--size=small`). Process
details: root [`AGENTS.md`](https://github.com/hilather/pmat-rust/blob/main/AGENTS.md).
Failed or blocked OPTs also get a short entry under
[`docs/lessons/`](https://github.com/hilather/pmat-rust/blob/main/docs/lessons/README.md).

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
- [ ] **OPT-03** — Global inrefs without full classic walk (partial: **lazy on-demand** for identify strong path; full classic still default for Inrefs tool / weak+indirect)
- [ ] **OPT-04** — Sizes / reachability / find on native model (partial: owned_size memoization + **Rust `owned_sizes` for largest --owned**)
- [x] **OPT-05** — Identify without full heap (lazy inrefs on walk set; strong path)
- [ ] **OPT-06** — Cheap / stub proxies for graph-only walks
- [ ] **OPT-07** — Reduce dual-residency memory (core + Perl)
- [ ] **OPT-08** — Hash outref O(K²) path
- [x] **OPT-09** — Index size gate (default skip fat `.pmat.idx` under 64 MiB unless `PMAT_IDX=1`)
- [x] **OPT-10** — Top-K / largest; **native owned precompute** for `largest --owned` (top-level list; deep tree residual)
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

### Bench harness: `largest` / `largest_owned` (v0.56.0 → current)

Phases added to `./bench/run-bench` (opt-in; not default suite):

```bash
./bench/run-bench --size=small,medium --phases=load,largest,largest_owned \
  --json=bench/results/largest.json
# or: --largest --largest-owned --largest-counts=5,3,2
```

Both phases drive the **shipped** `run_command` path (`largest` / `largest --owned` with tree counts K=5/3/2).

| Tier | Phase | **v0.56.0** (before OPT-10) | **Current** (OPT-10) | Speedup |
|------|-------|----------------------------|----------------------|---------|
| small (143k) | `largest` | 3.13 s | **0.31 s** | **~10×** |
| small | `largest_owned` | **134 s** | **11.4 s** | **~12×** |
| medium (666k) | `largest` | 14.3 s | **1.54 s** | **~9×** |
| medium | `largest_owned` | **843 s** (~14 min) | **72 s** | **~12×** |

Measured forced-rust, same fixtures (`small-mixed-n5000`, `medium-mixed-n25000`), `PMAT_IDX=0`. Before: git worktree at tag `v0.56.0`. After: tree with OPT-10 top-K + owned memoization.

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

### OPT-03 — Batch / native inrefs build  **[OPEN — partial]**

| | |
|--|--|
| **Problem** | Global inrefs first-use walks every proxy outref (materialize + full scan). |
| **Shipped** | **Lazy on-demand** reverse for Identify (strong path): CSR `inrefs_batch` candidates + re-filter via proxy `outrefs`. Default `load_tool(Inrefs)` stays classic full for oracle tools. |
| **Residual** | Weak/indirect/inferred completeness still needs classic full (`PMAT_INREFS_FULL` or automatic when those strengths are requested). Global first-use pause remains for full-index tools. |
| **Next** | Full 0.54 edge set in dense builder → lazy complete for all strengths. |

### OPT-04 — Sizes / reachability / find on native model  **[PARTIAL]**

| | |
|--|--|
| **Problem** | Full-heap tools re-walk proxies; structural/owned size and reachability do not use dense graph. |
| **Shipped** | Rust `Dump::owned_sizes` + `pmat_owned_sizes` / Core `owned_sizes` with 0.54-aligned CSR strong exclusive kids; `largest --owned` uses dense precompute + top-K materialize only. Exact score parity on exclusive AV roots; micro top-K **overlap** (≥3/5) vs classic. |
| **Residual** | Absolute owned scores / tail of top-K may drift where CSR still ≠ full 0.54 edges (regenerated micro dumps on EL8 can swap ranks 4–5); nested owned display tree still expensive (`PMAT_OWNED_FULL`); structural size / reachability / find native still open. |
| **Accept** | Structural sizes and reachability classes match 0.54 on fixture set |

### OPT-05 — Identify without full heap  **[DONE — strong path]**

| | |
|--|--|
| **Problem** | Identify loaded full Inrefs → full `heap()` materialize. |
| **Change** | Identify sets `_want_inrefs_lazy` under rust (strong path); on-demand CSR candidates + outrefs re-filter for walk set only. |
| **Files** | `Tool/Identify.pm`, `Tool/Inrefs.pm`; `t/100-oom-hotpath.t` |
| **Measured** | small identify **2.7 s → 0.02 s**, mat **143k → ~1.3k**; medium **~full heap → 0.00 s**, mat **~1.5k** |
| **Accept** | Identify paths usable without full heap; materialize ≪ heap_count |

### After OPT-05 / native largest --owned (2026-08-11)

| Path | Before (medium) | After (medium) | After (small) | Materialize |
|------|-----------------|----------------|---------------|-------------|
| **identify** (strong) | full heap + ~seconds | **~0.00 s** | **~0.02 s** | walk set only (~1.5k) |
| **largest --owned** | **~72 s** (v0.57 tree) / **843 s** (v0.56) | **~0.9 s** | **~0.14 s** | top-K only (~few proxies) |

**Native owned ranking residual:** `Dump::owned_sizes` uses dense CSR strong exclusive children after 0.54-aligned strength fixes (ARRAY AvREAL, CODE stash/glob/outside/pads). Exact native==classic owned score is asserted on a **controlled exclusive AV root** (`t/100-oom-hotpath.t`). On mixed micro fixtures (gitignored, regenerated in CI), require classic top-1 ∈ native top-5 and ≥3/5 top-K address overlap — ranks 4–5 can still swap when CSR under-counts STASH exclusive kids. Display uses native scores. Deep nested owned tree still requires `PMAT_OWNED_FULL=1` (classic full materialize).

Residual: `largest --owned` default shows **top-level** list under rust native path. Global classic inrefs still full-heap when loaded without lazy request.

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
