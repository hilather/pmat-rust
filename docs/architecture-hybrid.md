# Hybrid architecture (Rust core + Perl shell)

## Goals

Reduce load time, query latency, and memory for large PMAT dumps while
preserving **full external parity** with Devel-MAT 0.54.

## Layers

```
┌─────────────────────────────────────────────────────────┐
│  bin/pmat + tools (Perl) — commands, plugins, UI        │
├─────────────────────────────────────────────────────────┤
│  Devel::MAT / Dumpfile / SV proxies (Perl + XS)         │
│    • PMAT_BACKEND=perl|rust|auto                        │
│    • Lazy blessed-hash proxies (one per ObjectId)        │
├─────────────────────────────────────────────────────────┤
│  C ABI (panic-contained)                                │
│    load · type_counts · batch_outrefs · batch_inrefs …  │
├─────────────────────────────────────────────────────────┤
│  Rust pmat-core                                         │
│    parser (≤ format minor 6) · dense ObjectId model     │
│    address→id map · forward + reverse edge tables       │
│    optional versioned `.pmat.idx` sidecar (PAR-110)     │
└─────────────────────────────────────────────────────────┘
```

## Backend modes

| Mode | Behavior |
|------|----------|
| `PMAT_BACKEND=rust` (default) | Forced Rust parse + dense graph. **No** silent Perl fallback. Load failure is a hard error. |
| `PMAT_BACKEND=perl` | Forced 0.54 Perl/XS dump load path. Oracle. |
| `PMAT_BACKEND=auto` | Prefer Rust when the native library is available; otherwise Perl. Fallback **must not** count as a Rust pass in tests. |

Default: **`rust`** (parity matrix complete). Use `PMAT_BACKEND=perl` for the 0.54 oracle path.

## Dense model (Rust)

- Contiguous `ObjectId` (`u32`) for every heap SV.
- Address → ObjectId map (64-bit dump addresses; never treated as native pointers).
- Per-object type, refcnt, size, blessed addr, type-specific payload.
- Contiguous CSR-style (or equivalent) **forward** and **reverse** edge tables with strength + description id.
- Binary-safe strings; IV/UV/NV preserved as in the dump (NV raw bytes retained for long-double dumps).

## Perl compatibility

- Public API remains blessed hash SV proxies in the legacy class hierarchy.
- One strongly cached proxy per ObjectId for dump lifetime (identity + `tool_*` keys),
  via `Dumpfile` heap map + `_proxy_by_id` under the Rust load path.
- Rust load materializes type-specific payloads (headers/ptrs/strs/bodies, magic,
  saved slots, contexts, stack, mortals) so Identify/Sizes/Reachability/plugins
  run unchanged on forced-Rust dumps.
- Hot graph queries also expose **batch** native CSR edges (`outrefs_batch` /
  `inrefs_batch` / `type_counts`) for differential and future non-materializing paths.
- `heap()` materializes all proxies when called (0.54 semantics).
- **OPT-01 (lazy proxies):** forced-Rust load does **not** eagerly build every
  heap proxy. Proxies are created on first `sv_at` / `rust_proxy_for_id` (one
  cached proxy per ObjectId); `heap()` materializes the full set (0.54
  semantics). See [performance.md](https://github.com/hilather/pmat-rust/blob/main/docs/performance.md).

## Persistent index (PAR-110)

On successful forced-Rust load (`pmat_load` / `Devel::MAT::Core->load`), pmat-core
may write a versioned sidecar **`<dump>.pmat.idx`** (never modifies the `.pmat`).

| Rule | Behavior |
|------|----------|
| Schema | Magic `PMATIDX\x01`, schema version 1 |
| Trust | Source size + 128-bit content digest + payload CRC-32 must all match |
| Miss / bad | Full re-parse; index rewritten when enabled |
| Disable | `PMAT_IDX=0` (or `false`/`off`/`no`) skips read and write |
| Probe | `Devel::MAT::Core::last_load_used_index()` after load |

Residual: index stores a full dense-model snapshot (not mmap/incremental); first
open pays parse + write cost; second open can skip re-parse when valid.

## Format

Source of truth: `doc/format.txt` and the 0.54 Dumper/loader. Supported format
version major 0, minor ≤ 6.

## Build

- Rust crate: `rust/pmat-core` → `libpmat_core` (cdylib + staticlib).
- Linked from `Build.PL` / XS when present; forced-Perl works without the crate.
