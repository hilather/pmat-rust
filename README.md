# pmat-rust (Devel::MAT 0.54 hybrid)

Modernization of [Devel-MAT](https://metacpan.org/dist/Devel-MAT) **0.54**
(Perl Memory Analysis Tool / `pmat`): Rust dense dump core + Perl compatibility
shell, with forced-Perl as the behavioral oracle.

## Status

| Backend | Role |
|---------|------|
| `PMAT_BACKEND=perl` (default) | 0.54 oracle path |
| `PMAT_BACKEND=rust` | Forced Rust parse + graph (hard fail if core missing) |
| `PMAT_BACKEND=auto` | Prefer Rust when built; fallback is not a Rust pass |

See `docs/architecture-hybrid.md`, `docs/parity/matrix.md`, and
`docs/agent-bundle/`.

## Build

Requirements: Perl ≥ 5.14, a C compiler, [Rust](https://rustup.rs/) (stable),
and CPAN deps listed in `Build.PL` / `META.json` (plus `Devel::MAT::Dumper`
for tests that generate dumps).

```bash
export PERL5LIB="$PWD/local/lib/perl5${PERL5LIB:+:$PERL5LIB}"   # if using local::lib
perl Build.PL
./Build
./Build test

# Optional Rust-forced smoke (after successful Core.so link)
PMAT_BACKEND=rust perl -Iblib/lib -Iblib/arch bin/pmat -q path/to/file.pmat summary
```

`Build.PL` runs `cargo build --release` for `rust/pmat-core` when `cargo` is
available and links `libpmat_core` only into `Devel::MAT::Core`.

## Benchmarks / fixtures

```bash
./bench/gen-fixture --list
./bench/run-bench --size=small
```

## CI / Rocky 8 RPM

GitHub Actions: **Rocky Linux 8** (`.github/workflows/ci-rocky8.yml`) — build
Rust core, `./Build test` (perl + rust backends), then package an installable
**`perl-Devel-MAT`** RPM (includes `libpmat_core.so`).

- Artifacts: `rocky8-rpm` on every CI run
- Tags `v*`: RPM attached to the GitHub Release

Local package build (on EL8):

```bash
./packaging/rpm/build-rocky8.sh
sudo dnf install ./dist/rpm/perl-Devel-MAT-*.el8.x86_64.rpm
```

See `packaging/README.md`.

## License

Same as Devel-MAT 0.54: Perl 5 (Artistic + GPL-1+). See `LICENSE`.
