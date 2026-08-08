# Packaging

## Rocky Linux 8 / RHEL 8 RPM

Produces **`perl-Devel-MAT`** with:

- `libpmat_core.so` in `/usr/lib64` (Rust dense dump core)
- Perl modules + XS (`Devel::MAT`, `Devel::MAT::Core`) in vendor paths
- Companion scripts: `pmat`, `pmat-counts`, …
- Vendored pure-Perl runtime deps under `vendor_perl` so install is usable without a separate `cpanm` pass

### Build on Rocky 8

```bash
# deps: gcc, perl-devel, rpm-build, rust/cargo, curl
./packaging/rpm/build-rocky8.sh
ls dist/rpm/*.rpm
```

Optional environment:

| Variable | Default | Meaning |
|----------|---------|---------|
| `PMAT_VERSION` | `0.57.0` (or from `v*` tag) | RPM Version |
| `PMAT_RELEASE` | `1` | RPM Release |
| `PMAT_DIST` | `.el8` | Dist tag |
| `PMAT_RPM_SKIP_TEST` | `0` | Set `1` to skip `./Build test` |

### Install

```bash
sudo dnf install ./dist/rpm/perl-Devel-MAT-*.el8.x86_64.rpm
pmat --help
PMAT_BACKEND=rust pmat -q dump.pmat summary
```

Default backend remains **`perl`**. Use `PMAT_BACKEND=rust` for the native core.

### CI

GitHub Actions workflow **CI Rocky 8** (`.github/workflows/ci-rocky8.yml`):

1. Builds Rust core, runs the full Perl test suite (both backends)
2. Builds the EL8 RPM
3. Uploads `rocky8-rpm` artifacts
4. On tags `v*`, attaches the RPM (and `libpmat_core.so`) to the GitHub Release

### Link / rpath notes

`Build.PL` honors:

- `PMAT_CORE_LIBDIR` — link-time search path for `libpmat_core`
- `PMAT_CORE_RPATH` — runtime rpath embedded in `Core.so` (RPM uses `/usr/lib64`)
