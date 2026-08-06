# Feature parity contract

Version 0.54 is the source of truth. The replacement must match it exactly for all externally observable behavior.

## Required parity surfaces

- Dump format acceptance and rejection
- All valid minor versions supported by 0.54
- Object types, flags, values, magic, blessing, roots, stack, contexts
- Public Perl API, classes, method names, context behavior, overloads
- Plugin discovery and lifecycle
- `tool_*` state stored on blessed SV hashes
- All commands, options, aliases, selectors, and help text
- Companion scripts and executables
- Reference graph semantics
- Reachability and identify behavior
- Size calculations and top-K rankings
- Output formatting, pagination, and interactive behavior
- TTY and non-TTY behavior
- Malformed input errors and warnings
- Packaging artifacts and installed module inventory

## Comparison modes

Use these comparison types:

- Exact: stdout, stderr, exit code, help text, errors, formatting
- Structured exact: API results converted to fields
- Semantic multiset: only when ordering is explicitly unspecified

Never normalize away:
- object addresses
- counts
- sizes
- edge strengths
- symbols
- names
- missing or extra results
- ordering that 0.54 deliberately defines

## Compatibility rule

Observed 0.54 behavior is the oracle even when it looks suboptimal. Any deliberate semantic change must be documented, disabled in compatibility mode, and tested separately.
