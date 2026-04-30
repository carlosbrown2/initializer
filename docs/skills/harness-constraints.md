# Harness Constraints

These are constraints inherited from the initializer template. They are not patterns this project discovered — they are lessons baked into the template's harness (`scripts/ralph/`, `scripts/hooks/`, `tests/hooks/`) and they apply to every project bootstrapped from it.

A project may add its own discovered patterns under `CLAUDE.md` `## Discovered Patterns`. The entries below stay here so CLAUDE.md does not carry inherited prose that future model upgrades would need to re-validate alongside genuinely project-specific patterns.

## Inherited patterns

### Bind checks to the property, not a proxy for it
model: claude-opus-4-7
Every `bounded` row in `docs/decision-register.md` is a candidate for "the bound is on a proxy, not the actual property." Shape regex (`P[123]\.[a-z-]+`) is a proxy for clause membership; single-phrase grep (`"This file is a starter rubric"`) is a proxy for project-specificity; literal `|| true` match is a proxy for the "soft-fail escape" bug class. Each holds for the obvious case and breaks under a slightly different attack on the same class. Tightening means binding the check to the actual property: membership in a canonical set extracted from the single source of truth (rubric `**P[123].name**` markers), a multi-clause test that includes both absence-of-starter and presence-of-project-specific-content, a regex covering every syntactic variant of the bug class. Apply when auditing any `bounded` row or weak-test P2 finding.

### One implementation, one library: hook sources what the tests import
model: claude-opus-4-7
When a pre-commit hook and a test suite both need the same parser / validator logic, put it in a sourceable library (`scripts/hooks/parsers.sh`) and have the generated hook and the bats suite both `source` it. The generated hook fails closed if the library is missing, so "forgot to re-run install.sh after editing parsers.sh" is a hard error instead of a silent drift. Pair with smoke tests that run each parser against the real committed registers — a legitimate register edit that no longer parses is caught before pre-commit. Applies to any new check: if production needs it and tests need it, source it from one place. Bind: `tests/hooks/parsers.bats` and the heredoc in `scripts/hooks/install.sh` both `source scripts/hooks/parsers.sh`.

### Promote a ritual-bounded row to bounded in a single commit
model: claude-opus-4-7
When an audit bead lands the mechanism a row was pending, update three things together: (1) the Enforcement cell names the file that does the enforcement (the register integrity hook validates that any path-shaped token exists on disk); (2) Status flips to `bounded`; (3) the matching bullet is removed from the "Pending promotions" section below the table. Missing any of the three leaves the register internally inconsistent. Same principle for broadening an existing `covered` failure-mode row: update the failure-mode description and the Check cell in the same commit so the register cannot claim a tighter bound than the check delivers. Bind: `docs/decision-register.md` and `docs/failure-modes.md` are the registers this pattern operates on.

### Gate-clause ordering: dependency-first, most-specific cause first
model: claude-opus-4-7
A single clause's exit code should report the most specific cause possible. Order the verification gate so parse-checks for sourced libraries precede the test runner that sources them (`bash -n scripts/hooks/parsers.sh` before `bats tests/hooks/`) — a syntax error in the library then surfaces as a readable `bash -n` failure, not as an opaque bats source error. Every new clause earns two mechanical checks: one that the clause does its job (corrupting its target causes non-zero exit) and one that the clause cannot be silently dropped later (a structural-presence assertion or a corruption test whose passing requires the clause). Forbiddances for bug classes (`|| true`, `.md` paths in a `bash -n` chain) live adjacent to the gate in the same prose block so a future editor sees them in peripheral vision.

### Snapshot volatile state once per iteration
model: claude-opus-4-7
If the same piece of external state is read twice in an iteration and one read happens after an agent has mutated it, the second read will silently see the wrong value and any log line downstream of that read is a proxy, not the property. In `ralph.sh`, the active bead id was captured once at iteration top and again after the agent ran; the agent had called `bd close` in between, so every successful iteration logged `bead=unknown`. Fix: one snapshot per iteration, reuse the variable. Applies to any loop that queries the same external tool around an agent invocation. Bind: `tests/hooks/ralph.bats` covers the BEAD_DONE confidence.log echo lines under the bug condition; `docs/failure-modes.md` row "scripts/ralph/ralph.sh BEAD_DONE confidence.log bead= field" pins the underlying bug class.
