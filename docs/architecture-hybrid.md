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
└─────────────────────────────────────────────────────────┘
```

## Backend modes

| Mode | Behavior |
|------|----------|
| `PMAT_BACKEND=perl` | Forced 0.54 Perl/XS dump load path. Oracle. |
| `PMAT_BACKEND=rust` | Forced Rust parse + dense graph. **No** silent Perl fallback on success path. Load failure is a hard error. |
| `PMAT_BACKEND=auto` | Prefer Rust when the native library is available; otherwise Perl. Fallback **must not** count as a Rust pass in tests. |

Default for this phase: **`perl`** (or auto only after documented readiness). Rust is never default while parity rows fail.

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

## Format

Source of truth: `doc/format.txt` and the 0.54 Dumper/loader. Supported format
version major 0, minor ≤ 6.

## Build

- Rust crate: `rust/pmat-core` → `libpmat_core` (cdylib + staticlib).
- Linked from `Build.PL` / XS when present; forced-Perl works without the crate.
