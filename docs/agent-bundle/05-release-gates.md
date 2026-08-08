# Release gates

The work is complete only when all of the following are true:

- Exact 0.54 source is pinned and reproducible.
- Every 0.54 feature has a parity ID.
- Every parity ID has an automated test.
- Original tests pass unchanged.
- Forced Perl backend passes parity.
- Forced Rust backend passes parity.
- All six executables pass differential tests.
- All supported dump variants pass.
- All malformed-input tests pass.
- Plugin compatibility passes unchanged.
- Object identity passes.
- TTY and non-TTY formatting pass.
- Pagination and cancellation pass.
- Persistent index validation and corruption recovery pass.
- Performance targets are documented and measured.
- No known parity gap remains open.

## Non-negotiable rules

- Never hide Rust failures behind fallback in tests.
- Never make the Rust backend default while a parity row is failing.
- Never delete the Perl backend until the Rust path has full parity.
- Never reduce compatibility by “fixing” legacy behavior without an explicit compatibility-mode control.
- Standing process (performance first, docs, regression tests, benches every commit): root [`AGENTS.md`](../../AGENTS.md).
- **Release notes** for each `v*` tag must capture **all** changes since the previous release (full range, not the last commit only). See `AGENTS.md` § Releases and release notes.
