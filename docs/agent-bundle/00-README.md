# PMAT / Devel::MAT agent bundle

This bundle packages the modernization plan into taskable Markdown files for an implementation agent.

## Standing process (read first)

**Day-to-day agent rules live in the repo root [`AGENTS.md`](../../AGENTS.md):**

- **Performance first** (with oracle parity as hard gate)
- **Docs updated in the same change**
- **Regression tests for every behavior/optimization change**
- **Benchmarks refreshed on every performance-affecting commit** (`docs/performance.md` + harness)
- **Failed attempts + hard-won Perl/Rust semantics** → [`docs/lessons/`](../lessons/README.md) (light index; detail on demand)

This directory is historical/phased modernization context; `AGENTS.md` is the standing SoT for how to work.

## File map

- `01-executive-summary.md` - overall goal and constraints
- `02-current-architecture.md` - version 0.54 architecture and hotspots
- `03-feature-parity-contract.md` - what must be preserved
- `04-agent-workplan.md` - phased implementation plan with TODOs and gates
- `05-release-gates.md` - completion criteria and test policy
- `06-master-instructions.md` - copy-paste instructions for the agent

## Operating rules

- Treat version 0.54 as the oracle.
- Do not accept performance improvements that break parity.
- Prefer a Rust core with Perl compatibility retained until parity is proven.
- Every unknown behavior needs a characterization test.
- Every output change needs explicit review.
- Keep documentation, regression tests, and performance numbers in lockstep with code (see root `AGENTS.md`).
