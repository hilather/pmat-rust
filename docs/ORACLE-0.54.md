# Oracle pin: Devel-MAT 0.54

Version **0.54** is the behavioral oracle for this modernization. Observed 0.54
behavior wins over “cleaner” alternatives unless an explicit compatibility-mode
control is introduced and tested separately.

## Provenance

| Item | Value |
|------|--------|
| Distribution | Devel-MAT 0.54 |
| Author | Paul Evans (`PEVANS` / leonerd@leonerd.org.uk) |
| CPAN tarball | `https://cpan.metacpan.org/authors/id/P/PE/PEVANS/Devel-MAT-0.54.tar.gz` |
| Tarball sha256 | `083d80a9e6abf6cd02c29f22cf101f7e1b94a85fe1bf31dbeb152f76caca5183` |
| In-repo package | `package Devel::MAT 0.54` (`lib/Devel/MAT.pm`) |
| Format reference | `doc/format.txt` (PMAT format minor ≤ 6) |
| Agent-bundle source | `docs/agent-bundle/` (from `pmat_agent_bundle`) |

## Baseline git import

Initial import commit message: `Import Devel-MAT 0.54 from CPAN`  
Tag: `v0.54` (when present).

## Rules (from agent bundle)

- Never hide Rust failures behind Perl fallback in tests.
- Never make Rust the default backend while a parity row is failing.
- Never delete the Perl backend before full parity.
- Never modify the source `.pmat` file.
- Never allow a Rust panic across the FFI boundary.
- One FFI call per edge/object in a hot loop is forbidden.

## Backend control

```bash
export PMAT_BACKEND=perl   # default oracle path
export PMAT_BACKEND=rust   # forced Rust (hard error if core unavailable)
export PMAT_BACKEND=auto   # prefer Rust when built; fallback not a Rust pass
```

See also: `docs/architecture-hybrid.md`, `docs/parity/matrix.md`, `docs/agent-bundle/`.
