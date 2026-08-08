# pmat-rust

### Perl Memory Analysis Tool · hybrid Rust core

**Offline heap analysis for Perl** — load a `.pmat` dump, explore leaks and bloat in an interactive shell, and keep full **Devel::MAT 0.54** behavior while a dense **Rust** parser and graph engine take over the hot path.

[![CI Rocky 8](https://github.com/hilather/pmat-rust/actions/workflows/ci-rocky8.yml/badge.svg)](https://github.com/hilather/pmat-rust/actions/workflows/ci-rocky8.yml)
[![Oracle](https://img.shields.io/badge/oracle-Devel%3A%3AMAT%200.54-b7410e?logo=perl&logoColor=white)](https://metacpan.org/dist/Devel-MAT)
[![Format](https://img.shields.io/badge/PMAT%20format-major%200%20·%20minor%20≤%206-0f766e)](doc/format.txt)
[![Backend](https://img.shields.io/badge/PMAT__BACKEND-perl%20%7C%20rust%20%7C%20auto-1d4ed8)](#backend-modes)
[![RPM](https://img.shields.io/badge/package-EL8%20RPM-ee0000?logo=redhat&logoColor=white)](#install-rocky--rhel-8-rpm)
[![License](https://img.shields.io/badge/license-Perl%20(Artistic%20%2B%20GPL--1%2B)-555)](LICENSE)
[![Rust](https://img.shields.io/badge/pmat--core-Rust%202021-dea584?logo=rust&logoColor=white)](rust/pmat-core)

```text
  ┌──────────────────────────────────────────────────────────┐
  │  bin/pmat  ·  tools  ·  plugins  ·  terminal UI  (Perl)  │
  ├──────────────────────────────────────────────────────────┤
  │  Devel::MAT  ·  Dumpfile  ·  SV proxies  ·  XS           │
  │            PMAT_BACKEND = perl | rust | auto             │
  ├──────────────────────────────────────────────────────────┤
  │  C ABI (panic-contained)  load · counts · batch edges    │
  ├──────────────────────────────────────────────────────────┤
  │  pmat-core (Rust)  dense ObjectId model · CSR graphs     │
  │                   optional .pmat.idx sidecar (PAR-110)   │
  └──────────────────────────────────────────────────────────┘
```

---

## Why this exists

[Devel::MAT](https://metacpan.org/dist/Devel-MAT) is the gold-standard offline memory debugger for Perl: capture a heap dump from a running (or dying) process, then inspect it later on any machine. Classic 0.54 does the job — but large dumps hurt on:

| Bottleneck | Effect on big heaps |
|------------|---------------------|
| Eager per-SV Perl hashes | Memory + cache pressure |
| Many small parse reads | Slow load |
| Full-heap rescans | High query latency |
| Lazy reverse-edge build | First-use stalls |
| Quadratic hash key walks | Pathological HASH outrefs |

**pmat-rust** modernizes the **data path**, not the UX. The interactive `pmat` shell, plugin tools, and public API stay Perl-compatible. Parsing, dense object storage, and graph tables move into **`rust/pmat-core`**, selected via `PMAT_BACKEND`.

Upstream behavior is pinned to **Devel-MAT 0.54** as the behavioral oracle — see [`docs/ORACLE-0.54.md`](docs/ORACLE-0.54.md).

---

## Features

### Capture → analyze workflow

1. **Dump** a live Perl process with [`Devel::MAT::Dumper`](https://metacpan.org/pod/Devel::MAT::Dumper) (separate CPAN dist — light footprint on production hosts).
2. **Load** the `.pmat` file in `pmat` (or companion scripts).
3. **Hunt** leaks, retained objects, and oversized SVs with interactive tools.

```bash
# Capture on crash
perl -MDevel::MAT::Dumper=-dump_at_DIE your-app.pl

# Explore offline
pmat your-app.pl.pmat
# → summary banner, then interactive: pmat>
```

### Interactive analysis shell

| Command area | What you get |
|--------------|--------------|
| **summary** / **count** | Dump metadata + type histogram (bytes & blessed counts) |
| **largest** / **sizes** | Structure & owned size; find multi-GiB SCALAR/HASH/ARRAY offenders |
| **identify** / **inrefs** / **outrefs** | Who holds this SV? Full referrer graph back to roots |
| **reachability** | Root-set classification (symtab, lexical, padlist, user, …) |
| **find** / **symbols** / **roots** | Search by pattern, walk the symbol table, list known roots |
| **show** / **stack** / **callers** | Inspect SV details, call stack, contexts at dump time |
| **strtab** | Shared-string table (`PL_strtab`) analysis |
| **list-dangling-ptrs** | Broken pointer diagnostics |

Tools load as pluggable `Devel::MAT::Tool::*` modules — extend the shell without forking the core.

### Companion CLI tools

| Binary | Purpose |
|--------|---------|
| [`bin/pmat`](bin/pmat) | Main interactive / one-shot command shell |
| [`bin/pmat-diff`](bin/pmat-diff) | Diff two dumps (appeared / disappeared SVs) |
| [`bin/pmat-counts`](bin/pmat-counts) | Streaming type-count deltas across multiple dumps |
| [`bin/pmat-leakreport`](bin/pmat-leakreport) | Multi-dump leak candidates (appear then never free) |
| [`bin/pmat-list-orphans`](bin/pmat-list-orphans) | Unreachable / orphaned objects |
| [`bin/pmat-cat-svpv`](bin/pmat-cat-svpv) | Dump string payload of a SCALAR(PV) |

### Hybrid Rust core (`pmat-core`)

- **Zero-dep** Rust crate (`cdylib` + `staticlib` + `rlib`), LTO release builds
- **Panic-safe C ABI** — errors as codes, never unwind into Perl (`PMAT_ERR_*`)
- **Dense `ObjectId` (`u32`)** model, address→id map, CSR-style forward & reverse edges
- **Batch graph APIs** — `type_counts`, `outrefs_batch`, `inrefs_batch`
- Full SV materialization for Identify / Sizes / Reachability / plugins under forced Rust
- **Persistent `.pmat.idx`** (PAR-110) — versioned sidecar after successful Rust load; validated by content digest + CRC; never mutates the `.pmat`
- Format: **major 0, minor ≤ 6** ([`doc/format.txt`](doc/format.txt))

### Parity-first engineering

**All** external 0.54 parity gates (including **PAR-110** persistent index) are **`pass`** under `PMAT_BACKEND=rust`. Track status in [`docs/parity/matrix.md`](docs/parity/matrix.md). Architecture notes: [`docs/architecture-hybrid.md`](docs/architecture-hybrid.md). Performance baselines and the optimization backlog: [`docs/performance.md`](docs/performance.md).

### Benchmarks & fixtures

Sized fixtures from **micro (~200 SVs)** through synthetic **huge (up to ~17 GiB)** dumps — measure `load`, `inrefs`, heap walk, counts, sizes, reachability, identify. See [`bench/README.md`](bench/README.md).

### Rocky / RHEL 8 RPM packaging

CI builds installable **`perl-Devel-MAT`** RPMs with `libpmat_core.so`, XS, modules, and companion scripts. See [Install (Rocky / RHEL 8 RPM)](#install-rocky--rhel-8-rpm).

---

## Quick start

### Requirements

| Need | Notes |
|------|--------|
| **Perl** ≥ 5.14 | With a C compiler for XS |
| **Rust** stable | [`rustup`](https://rustup.rs/) — optional but required for the Rust backend |
| **CPAN deps** | From `Build.PL` / `META.json` (`Module::Build`, `Devel::MAT::Dumper`, `Test2::V0`, …) |

### Build & test from source

```bash
git clone https://github.com/hilather/pmat-rust.git
cd pmat-rust

# Optional local::lib
export PERL5LIB="$PWD/local/lib/perl5${PERL5LIB:+:$PERL5LIB}"

perl Build.PL          # runs cargo build --release for rust/pmat-core when cargo is present
./Build
./Build test
```

`Build.PL` links `libpmat_core` **only** into `Devel::MAT::Core` (so the Rust runtime is not dual-loaded via `MAT.xs`). Without cargo, the build still succeeds on the pure Perl/XS oracle path.

Link-time knobs (used by the RPM build):

| Variable | Meaning |
|----------|---------|
| `PMAT_CORE_LIBDIR` | Search path for `libpmat_core` at link time |
| `PMAT_CORE_RPATH` | Runtime rpath embedded in `Core.so` (RPM uses `/usr/lib64`) |

### Run the shell

```bash
# One-shot summary (quiet)
./bin/pmat -q path/to/file.pmat summary

# Interactive
./bin/pmat path/to/file.pmat
pmat> count
pmat> largest
pmat> identify 0x55c2bdce2778
```

From a built tree you may need:

```bash
perl -Iblib/lib -Iblib/arch bin/pmat -q dump.pmat summary
```

---

## Install (Rocky / RHEL 8 RPM)

CI produces a **`perl-Devel-MAT`** package that includes:

- `libpmat_core.so` → `/usr/lib64`
- Perl modules + XS (`Devel::MAT`, `Devel::MAT::Core`) in vendor paths
- Companion scripts (`pmat`, `pmat-counts`, …)
- Vendored pure-Perl runtime deps under `vendor_perl` (no separate `cpanm` pass)

### From GitHub Actions / Releases

- Every CI run uploads a **`rocky8-rpm`** artifact
- Tags `v*` attach the RPM (and `libpmat_core.so`) to the [GitHub Release](https://github.com/hilather/pmat-rust/releases)

### Build the RPM locally (EL8)

```bash
# Needs: gcc, perl-devel, rpm-build, rust/cargo, curl
./packaging/rpm/build-rocky8.sh
ls dist/rpm/*.rpm

sudo dnf install ./dist/rpm/perl-Devel-MAT-*.el8.x86_64.rpm
pmat --help
PMAT_BACKEND=rust pmat -q dump.pmat summary
```

| Variable | Default | Meaning |
|----------|---------|---------|
| `PMAT_VERSION` | `0.54.1` | RPM Version |
| `PMAT_RELEASE` | `1` | RPM Release |
| `PMAT_DIST` | `.el8` | Dist tag |
| `PMAT_RPM_SKIP_TEST` | `0` | Set `1` to skip `./Build test` |

Details: [`packaging/README.md`](packaging/README.md).

---

## Backend modes

Control the dump loader with **`PMAT_BACKEND`**:

| Mode | Behavior |
|------|----------|
| **`rust`** (default) | Forced Rust parse + dense graph. Hard error if `pmat-core` is missing. **No silent fallback.** |
| **`perl`** | Forced 0.54 Perl/XS path — **oracle** |
| **`auto`** | Prefer Rust when the native library is available; otherwise Perl. Auto fallback **must not** count as a Rust pass in tests. |

```bash
# Default is rust when Core is linked (unset PMAT_BACKEND)
./bin/pmat -q file.pmat summary

# Explicit oracle path
export PMAT_BACKEND=perl
./bin/pmat -q file.pmat summary

# Prefer Rust when built, fall back to Perl if not
export PMAT_BACKEND=auto
```

Resolution logic lives in [`lib/Devel/MAT/Backend.pm`](lib/Devel/MAT/Backend.pm).

### Persistent index (`PMAT_IDX`)

Under the Rust load path, pmat-core may write **`<dump>.pmat.idx`** beside the dump (schema v1). A later open reuses it only when magic/schema, source size, content digest, and payload CRC all match; otherwise it full-parses and rewrites the sidecar.

| Variable | Behavior |
|----------|----------|
| *(unset)* / `PMAT_IDX=1` | Index read/write enabled (default on Rust path) |
| `PMAT_IDX=0` / `false` / `off` / `no` | Skip index entirely |

```bash
# Second open can use the sidecar (probe via Core API)
PMAT_BACKEND=rust perl -Iblib/lib -Iblib/arch -MDevel::MAT::Core -e '
  my $p = shift;
  Devel::MAT::Core->load($p);
  print "used_index=", Devel::MAT::Core::last_load_used_index(), "\n";
' path/to/file.pmat
```

---

## Usage recipes

### Find a runaway string or structure

```text
pmat> largest
SCALAR(PV) at 0x6a47708: 1.6 GiB
...
pmat> identify 0x6a47708
pmat> inrefs 0x6a47708
```

### Type histogram

```text
pmat> count
  Kind       Count (blessed)        Bytes (blessed)
  ARRAY        182         0     16.0 KiB
  CODE         182         0     22.8 KiB
  ...
```

### Call stack at dump time

```text
pmat> callers
caller(0): CODE(PP) at 0x...=&main::__ANON__ => void
  at t/test.pl line 49
```

### Diff two snapshots

```bash
pmat-diff before.pmat after.pmat
```

### Leak hunt across a sequence of dumps

```bash
pmat-leakreport snap1.pmat snap2.pmat snap3.pmat
```

### Programmatic load

```perl
use Devel::MAT;

my $pmat = Devel::MAT->load( "app.pl.pmat" );
my $df   = $pmat->dumpfile;

$pmat->run_command( Commandable::Invocation->new( "summary" ) );

my $sv = $pmat->find_symbol( '$MyApp::cache' );
# ...
```

New users: start with the POD guide [`Devel::MAT::UserGuide`](lib/Devel/MAT/UserGuide.pod). Tool authors: [`Devel::MAT`](lib/Devel/MAT.pm) + [`Devel::MAT::Tool`](lib/Devel/MAT/Tool.pod).

---

## Project layout

```text
pmat-rust/
├── bin/                 # pmat + companion CLIs
├── lib/Devel/MAT/       # Perl API, tools, Dumpfile, Backend, Core XS
├── rust/pmat-core/      # Dense parser + graph + C ABI + .pmat.idx
│   ├── src/{lib,parse,ffi,index}.rs
│   └── include/pmat_core.h
├── t/                   # Oracle + parity + backend + index tests
├── bench/               # Fixture generator + benchmark harness
├── fixtures/            # Generated dumps (local; gitkept)
├── packaging/rpm/       # Rocky 8 RPM spec + build script
├── doc/format.txt       # PMAT binary format
├── docs/
│   ├── architecture-hybrid.md
│   ├── ORACLE-0.54.md
│   ├── parity/matrix.md
│   └── agent-bundle/    # Modernization workplan
└── .github/workflows/   # Rocky Linux 8 CI + RPM
```

---

## Benchmarks

```bash
./bench/gen-fixture --list
./bench/gen-fixture              # micro + small by default
./bench/run-bench --size=small
./bench/run-bench --json=bench/results/baseline.json

# Production dump
./bench/run-bench --file=/path/to/prod.pmat --json=bench/results/prod.json
```

| Tier | Scale | Typical use |
|------|-------|-------------|
| `micro` | ~200 nodes | Unit / CI fixtures |
| `small` | ~5k nodes | Default iteration |
| `medium` / `large` / `xlarge` | 25k–400k | Stress graph tools |
| `huge` / `17G` | synthetic bulk up to multi-GiB | Load & table scaling |

Phases measured: **load**, **inrefs**, **heap_walk**, **count**, **sizes_struct** / **sizes_owned**, **reachability**, **identify** (RSS via `/proc` when available).

---

## Testing & CI

```bash
./Build test

# Force Rust backend for parity tests (when core is linked)
PMAT_BACKEND=rust prove -Iblib/lib -Iblib/arch t/9*.t
```

Notable test groups:

| Tests | Focus |
|-------|--------|
| `t/00`–`t/10`, `t/50` | Classic 0.54 unit + tool coverage |
| `t/90`–`t/91` | Fixtures & bench CLI |
| `t/92` | Backend mode selection |
| `t/93`–`t/95` | Perl↔Rust differential & remaining parity |
| `t/96` | Persistent `.pmat.idx` (PAR-110) |
| `t/99` | POD |

**CI (Rocky Linux 8):** [`.github/workflows/ci-rocky8.yml`](.github/workflows/ci-rocky8.yml)

1. Install toolchain + CPAN deps  
2. `cargo build --release` for `pmat-core`  
3. `./Build` + `./Build test` (perl + rust backend smokes)  
4. Build **`perl-Devel-MAT`** RPM → `rocky8-rpm` artifact  
5. On tags `v*`, attach RPM to the GitHub Release  

---

## Documentation map

| Doc | Contents |
|-----|----------|
| [**AGENTS.md**](AGENTS.md) | **Standing agent rules** — performance first, docs, tests, benches, lessons |
| [lessons/](docs/lessons/) | Failed OPT attempts + hard-won Perl/Rust semantics (light index) |
| [UserGuide (POD)](lib/Devel/MAT/UserGuide.pod) | Capture + analysis introduction |
| [architecture-hybrid.md](docs/architecture-hybrid.md) | Layer diagram, dense model, backends |
| [parity/matrix.md](docs/parity/matrix.md) | Feature-parity gate table |
| [performance.md](docs/performance.md) | Baselines + OPT-01…OPT-12 backlog |
| [ORACLE-0.54.md](docs/ORACLE-0.54.md) | Version pin & rules of engagement |
| [agent-bundle/](docs/agent-bundle/) | Executive plan, workplan, release gates |
| [doc/format.txt](doc/format.txt) | Binary dump format |
| [bench/README.md](bench/README.md) | Fixture & bench CLI details |
| [packaging/README.md](packaging/README.md) | EL8 RPM build & install |

---

## Design principles

1. **Performance first** — large-dump wall time and RSS drive design; measure every change (`docs/performance.md`, `bench/`).
2. **Oracle wins** — 0.54 observed behavior beats “cleaner” rewrites unless an explicit compatibility mode is tested.
3. **No silent mis-attribution** — Rust failures never hide behind Perl fallback in tests; `PMAT_BACKEND=rust` hard-fails.
4. **Docs + tests + benches with the code** — same commit; see [AGENTS.md](AGENTS.md).
5. **Keep the shell** — plugins, commands, and blessed SV proxies stay familiar.
6. **Dense native model first** — layout and algorithms deliver more than a pure language rewrite.
7. **Safe FFI** — panic-contained C ABI; no one-FFI-call-per-edge hot loops.
8. **Never mutate** the source `.pmat` file.
9. **Never trust an unvalidated index** — schema, source digest, and payload CRC must all match before reuse.

---

## Status

| Area | State |
|------|--------|
| Perl/XS oracle path | Default, fully supported |
| Rust load + dense graph | Forced mode; **all** external parity rows **pass** |
| Batch CSR edge / count APIs | Available on Rust path |
| EL8 RPM packaging | CI + local build script; release assets on tags |
| Persistent `.pmat.idx` | **pass** (schema v1, digest+CRC; `PMAT_IDX=0` disables) |
| Default backend | **`rust`** (use `PMAT_BACKEND=perl` for oracle) |

This is a **hybrid modernization** of Devel-MAT 0.54, not a drop-in CPAN re-release under a new name. Upstream author: Paul Evans (`PEVANS`). Hybrid work lives in this repository.

---

## License

Same as Devel-MAT 0.54: **Perl 5** — [Artistic License](LICENSE) and/or [GPL-1+](LICENSE).

`pmat-core` crate: `Artistic-1.0-Perl OR GPL-1.0-or-later`.

---

## Links

- **Upstream CPAN:** [Devel-MAT](https://metacpan.org/dist/Devel-MAT)
- **Dumper (capture only):** [Devel::MAT::Dumper](https://metacpan.org/dist/Devel-MAT-Dumper)
- **Releases / RPMs:** [github.com/hilather/pmat-rust/releases](https://github.com/hilather/pmat-rust/releases)
- **Issues / CI:** [github.com/hilather/pmat-rust](https://github.com/hilather/pmat-rust)

```bash
# Open a dump and start hunting:
pmat your-app.pl.pmat
pmat> largest
```
