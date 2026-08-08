# Agent instructions — pmat-rust

Standing rules for every agent (human or automated) working in this repository.
These override generic “ship code first” habits. Read this before non-trivial work.

## Priority order (always)

1. **Performance** — wall time and peak memory on large dumps are the product goal.
2. **Correctness / 0.54 oracle** — never ship a speedup that breaks forced-perl or forced-rust parity.
3. **Documentation + benchmarks** — must land in the **same commit** as the code change.
4. **Regression tests** — every behavior fix or optimization needs a test that would fail without it.

If two goals conflict, **prefer a slower correct path over a fast wrong one**, then document the residual and open an OPT item. Do not claim performance wins without measurements.

---

## Performance is first-class

- Treat load, first-use tool pauses (`summary`, `count`, `inrefs`, `largest --owned`, identify), and dual-residency RSS as primary metrics.
- Prefer paths that **avoid full `heap()` materialization** under forced Rust when oracle parity allows.
- Never re-introduce eager full-proxy materialize on open without an explicit, measured, documented reason.
- Hot paths: no one-FFI-call-per-edge; batch / dense / CSR where parity allows; classic proxy walks only when required for 0.54 edges/strengths.
- Source of truth for OPT backlog and measured numbers: [`docs/performance.md`](docs/performance.md).
- Harness details: [`bench/README.md`](bench/README.md).

### Benchmarks — update on every commit

**Every commit that changes runtime behavior, defaults, tools, load path, index policy, or Rust core must update performance evidence in the same commit.**

Minimum for performance-affecting commits:

1. Run the bench harness (at least **small**; **medium** when the change targets large-dump cost):

   ```bash
   export PERL5LIB="$PWD/blib/lib:$PWD/blib/arch:$PWD/local/lib/perl5${PERL5LIB:+:$PERL5LIB}"
   ./Build   # after rust/pmat-core rebuild if needed
   ./bench/run-bench --size=small,medium --json=bench/results/after-<short-desc>.json
   # When touching largest / owned sizes, also:
   ./bench/run-bench --size=small,medium --phases=load,largest,largest_owned \
     --json=bench/results/after-largest.json
   ```

2. Update **`docs/performance.md`**:
   - Refresh summary tables (load / summary / count / inrefs / owned / etc.) with **before → after** and date/context.
   - Flip OPT checkboxes only when code + tests + numbers match.
   - State **residuals honestly** (e.g. classic inrefs still full-heap).

3. When results are durable baselines (release, major OPT ship), also refresh committed JSON under `bench/results/baseline/` (see that directory’s README).

4. Commit message must mention performance impact (e.g. `load ~6×`, `inrefs residual`, `no bench change: docs-only`).

**Docs-only / comment-only / pure test-fixture renames** may skip a full re-bench, but the commit message must say so. If unsure, run at least `--size=small`.

Parity-only fixes that do not change the hot path still need a short note in `docs/performance.md` if they block or re-enable an optimization (e.g. “CSR inrefs blocked: …”).

---

## Always keep documentation up to date

Same change set as the code — not a follow-up PR “later”.

| If you change… | Update… |
|----------------|---------|
| Load / tools / backends / env vars | `docs/performance.md`, `docs/architecture-hybrid.md`, README usage if user-facing |
| Feature parity status | `docs/parity/matrix.md` (+ `matrix.json` if used) |
| Oracle / process rules | `docs/ORACLE-0.54.md` |
| Index / FFI / core API | architecture + any parity rows + performance OPT notes |
| Bench harness / tiers | `bench/README.md` |
| Agent process | this file + `docs/agent-bundle/` if standing process changes |

Rules:

- Prefer editing **existing** docs over new parallel pages.
- Absolute HTTPS links in user-facing docs when linking across files for release notes; in-repo agent docs may use repo-relative paths.
- Do not mark OPT or parity rows **done** without implementation + tests + measured evidence.
- Document limitations and fallbacks when claiming new capabilities.

---

## Always add regression tests

No behavior change without a test that **drives the shipped entry point**.

| Change type | Test expectation |
|-------------|------------------|
| Bug fix | Failing case before fix (or new test that fails on main without the patch) |
| Optimization | Parity / oracle test so a wrong fast path cannot land; materialize-count assertions when lazy is the point |
| New API / env / policy | Unit or integration test for default + force/off cases |
| Tool command path | Real `Devel::MAT->load` + `run_command` / `load_tool`, not a reimplemented counter |

Requirements:

- Run under **`PMAT_BACKEND=perl` and `PMAT_BACKEND=rust`** when the path is backend-sensitive.
- Prefer fixtures under `fixtures/` or self-dumps via `Devel::MAT::Dumper` in `t/`.
- No test theater: do not hard-code expected values that skip the code under test; do not only assert “lives”.
- Name new tests clearly (`t/9x-*.t`); keep them in the default `prove -r t/` suite.

Existing anchors: `t/93-perl-rust-diff.t`, `t/97-lazy-proxies.t`, `t/98-largest-owned.t`, `t/99-hotpath-lazy.t`, `t/10tool-*.t`.

---

## Definition of done (per change)

Before claiming complete or asking to commit:

- [ ] Forced-perl and forced-rust tests for the affected area are green
- [ ] New/updated regression tests are in-tree and would catch the bug or a wrong optimization
- [ ] Docs for behavior, OPT status, and residuals are updated
- [ ] Benchmarks run and `docs/performance.md` (and baseline JSON if applicable) reflect current numbers
- [ ] Residuals and tradeoffs stated honestly (no silent capability claims)

---

## Releases and release notes

When tagging a release (`v*`) or publishing a GitHub Release:

1. **Capture all changes since the previous release tag** — not only the last commit. Sources:
   - `git log <prev-tag>..HEAD` (commits)
   - `git diff <prev-tag>..HEAD --stat` (files)
   - OPT / parity / packaging / CI / docs deltas
2. **Release notes must be complete**, including at least:
   - **Highlights** — user-visible performance and behavior
   - **All significant code changes** — tools, Rust core, index policy, backends, packaging
   - **Tests** added or extended
   - **Docs** paths (absolute `https://github.com/…/blob/<tag>/…` links pinned to the tag)
   - **Measured performance** before/after or vs prior release (cite `docs/performance.md`)
   - **Residuals / known limitations** (honest; do not omit OPT pullbacks)
   - **Upgrade / env notes** (e.g. `PMAT_IDX`, `PMAT_BACKEND`)
3. Prefer a structured body (Highlights, Changes since `vX.Y.Z`, Performance, Tests, Docs, Residual).
4. Tag message should summarize; **GitHub Release body is the full change capture**.
5. Do not publish a release that only says “bugfixes” when the range includes OPT, packaging, or agent-process changes — list them.

Process SoT for day-to-day work remains this file; historical parity plan: `docs/agent-bundle/`.

---

## Non-negotiables (parity + safety)

- Devel::MAT **0.54** is the behavioral oracle (`docs/ORACLE-0.54.md`).
- Never hide Rust failures behind auto-fallback in tests; `PMAT_BACKEND=rust` must hard-fail if Rust is required.
- Never mutate the source `.pmat` file; never trust an unvalidated `.pmat.idx`.
- Never allow a Rust panic across the FFI boundary.
- Blessed SV proxies and tool_* identity rules still apply (see agent-bundle / architecture).

Historical modernization plan (parity phases, release gates): [`docs/agent-bundle/`](docs/agent-bundle/).  
**Standing day-to-day process lives in this `AGENTS.md` file.**
