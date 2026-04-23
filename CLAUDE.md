# Project Rules

This is the **initializer template** itself. The project under development is the template — the ralph loop, the kickoff prompt, the hook installer, the registers, and the skill files that future projects are bootstrapped from.

## Architecture

- `project-kickoff-prompt.md` — the phase-by-phase outcome contract for any project bootstrapped from this template.
- `scripts/ralph/ralph.sh` — the long-running agent loop. Picks a ready bead, runs the agent, parses `<gate-result>`/`<confidence>` tags, auto-lands if policy allows.
- `scripts/ralph/prompt.md` — the per-iteration system prompt the loop feeds the agent.
- `scripts/hooks/install.sh` — installs the pre-commit chain (bead-type gate, scope enforcement, register integrity, review artifact validator, model-tag validator, CLAUDE.md size guard, commit-message format).
- `docs/failure-modes.md` and `docs/decision-register.md` — the two registers that every register-integrity hook parses.
- `docs/skills/` — domain skill files; `review-rubric.md` ships as a starter that each project refines in Phase 1.

## Code Standards

- Shell scripts: bash with `set -euo pipefail` (or `set -u` + explicit pipe handling where sourcing). Every script must be syntax-clean under `bash -n` **and** pass `shellcheck -x`. `shellcheck` catches the class of quoting / subshell / word-split bugs `bash -n` does not — and because this is a template, every downstream project inherits the clean-bash default.
- Parser logic in hooks uses awk with explicit column counts and escaped-pipe handling. Multi-line continuation rows in registers are rejected by design.
- Markdown registers use single-line rows with >= 5 columns. Bounding-mechanism cells that name a file must reference a file that exists on disk.
- External tool versions that hooks parse output from (currently `bd`) are pinned in this file's `## Pinned Tool Versions` section and mechanically checked by the verification gate. A bd CLI format change can silently break every hook that reads its output; the pin turns that silent drift into a loud failure.

## Pinned Tool Versions

- `bd` (Beads CLI): **>= 0.3.0**. Gate clause `bd --version | grep -qE '^bd version ([1-9]|0\.([3-9]|[1-9][0-9]))'` fails if the installed version is older than 0.3.0 (the version whose `--json` output shape lib.sh and parsers.sh are built against). The regex matches the real `bd --version` output format (`bd version X.Y.Z ...`) and accepts `0.3.x`–`0.99.x` plus any `1.x+`.

## Verification Gate

```
bash -n scripts/ralph/ralph.sh && bash -n scripts/ralph/lib.sh && bash -n scripts/hooks/install.sh && bash -n scripts/hooks/parsers.sh && shellcheck -x scripts/ralph/ralph.sh scripts/ralph/lib.sh scripts/hooks/install.sh scripts/hooks/parsers.sh && bd --version 2>/dev/null | grep -qE '^bd version ([1-9]|0\.([3-9]|[1-9][0-9]))' && bats tests/hooks/
```

The gate parse-checks every shell script the pre-commit chain depends on (`parsers.sh` is sourced by the generated hook at runtime, so a syntax error there silently breaks register integrity), runs `shellcheck -x` across the full bash surface to catch quoting / subshell / word-split bugs that `bash -n` misses, verifies the `bd` CLI version against the pinned floor so a downstream-CLI format change surfaces as a gate failure rather than a silent hook no-op, and runs the full bats suite under `tests/hooks/` so parser and gate regressions surface mechanically.

Every clause must exit non-zero on real failure with no **soft-fail escape in a correctness chain** — this is the bug class that covers `|| true`, `|| :`, `|| 0`, `|| exit 0`, and any other trailer that swallows a non-zero exit. The name deliberately generalizes beyond the original `|| true` label because `||` precedence binds the trailer to the whole `&&` chain regardless of which no-op is on the right. Do not append any such trailer anywhere in the gate (see `docs/failure-modes.md`). Markdown files (e.g. `scripts/ralph/prompt.md`) are not parseable as bash and must not be added to the `bash -n` chain.

The gate is enforced at **two points**, and both must agree before a push reaches the remote:

1. **During the bead (soft):** the agent runs the gate and self-reports via `<gate-result>PASS|FAIL</gate-result>`. `scripts/ralph/ralph.sh` parses the tag and persists it to `.last-gate-result` (gitignored) so downstream tools can compare.
2. **On `git push` (hard):** the pre-push hook installed by `scripts/hooks/install.sh` extracts this gate command, re-runs it, and blocks the push if the real exit code is non-zero. If `.last-gate-result` says PASS but the re-run fails, the block message calls out the divergence explicitly.

## Invariants

- The registers (`docs/failure-modes.md`, `docs/decision-register.md`) must parse cleanly under the integrity hooks in `scripts/hooks/install.sh`. Any edit to either register must preserve: single-line rows, >= 5 columns, valid status in the last cell, and existing paths for any path-shaped token in bounding-mechanism / enforcement columns.
- `CLAUDE.md` stays under 200 lines (size-guard hook). Domain knowledge goes to `docs/skills/`.
- Every `### ` entry under `## Discovered Patterns` carries a `model:` tag.
- No hook is ever bypassed with `--no-verify`. If a hook is wrong, fix the hook.
- Bead id shape lives in exactly one place per library: `BEAD_ID_REGEX` in `scripts/ralph/lib.sh` and `PARSERS_BEAD_ID_REGEX` in `scripts/hooks/parsers.sh`. A bats smoke test in `tests/hooks/parsers.bats` asserts the two values are equal byte-for-byte. Never inline the regex at a call site — reference the constant.
- `bd` CLI output is parsed only via `--json` + `jq`. Human-formatted output is not part of the bd contract and must not be a load-bearing parser input.
- `archive.txt` is a machine-parsed artifact. Every `bead_done=true` entry in `confidence.log` with a real bead id must have a matching `## <date> - <bead-id>` block in `archive.txt` (checked by `archive_schema_check` in the gate). This keeps "agent wrote a progress entry" from being a proxy for "the entry is discoverable by future agents."

## Confidence Routing

The template itself ships `auto-land: high` as the safer default for every project bootstrapped from it. This template repo runs `auto-land: all` only because the gate is fully fleshed out and the human (you) is the only principal. Downstream projects should keep `high` until their gate is similarly strong.

auto-land: all

## Discovered Patterns

### Bind checks to the property, not a proxy for it
model: claude-opus-4-7
Every `bounded` row in `docs/decision-register.md` is a candidate for "the bound is on a proxy, not the actual property." Shape regex (`P[123]\.[a-z-]+`) is a proxy for clause membership; single-phrase grep (`"This file is a starter rubric"`) is a proxy for project-specificity; literal `|| true` match is a proxy for the "soft-fail escape" bug class. Each holds for the obvious case and breaks under a slightly different attack on the same class. Tightening means binding the check to the actual property: membership in a canonical set extracted from the single source of truth (rubric `**P[123].name**` markers), a multi-clause test that includes both absence-of-starter and presence-of-project-specific-content, a regex covering every syntactic variant of the bug class. Apply when auditing any `bounded` row or weak-test P2 finding.

### One implementation, one library: hook sources what the tests import
model: claude-opus-4-7
When a pre-commit hook and a test suite both need the same parser / validator logic, put it in a sourceable library (`scripts/hooks/parsers.sh`) and have the generated hook and the bats suite both `source` it. The generated hook fails closed if the library is missing, so "forgot to re-run install.sh after editing parsers.sh" is a hard error instead of a silent drift. Pair with smoke tests that run each parser against the real committed registers — a legitimate register edit that no longer parses is caught before pre-commit. Applies to any new check: if production needs it and tests need it, source it from one place.

### Promote a ritual-bounded row to bounded in a single commit
model: claude-opus-4-7
When an audit bead lands the mechanism a row was pending, update three things together: (1) the Enforcement cell names the file that does the enforcement (the register integrity hook validates that any path-shaped token exists on disk); (2) Status flips to `bounded`; (3) the matching bullet is removed from the "Pending promotions" section below the table. Missing any of the three leaves the register internally inconsistent. Same principle for broadening an existing `covered` failure-mode row: update the failure-mode description and the Check cell in the same commit so the register cannot claim a tighter bound than the check delivers.

### Gate-clause ordering: dependency-first, most-specific cause first
model: claude-opus-4-7
A single clause's exit code should report the most specific cause possible. Order the verification gate so parse-checks for sourced libraries precede the test runner that sources them (`bash -n scripts/hooks/parsers.sh` before `bats tests/hooks/`) — a syntax error in the library then surfaces as a readable `bash -n` failure, not as an opaque bats source error. Every new clause earns two mechanical checks: one that the clause does its job (corrupting its target causes non-zero exit) and one that the clause cannot be silently dropped later (a structural-presence assertion or a corruption test whose passing requires the clause). Forbiddances for bug classes (`|| true`, `.md` paths in a `bash -n` chain) live adjacent to the gate in the same prose block so a future editor sees them in peripheral vision.

### Snapshot volatile state once per iteration
model: claude-opus-4-7
If the same piece of external state is read twice in an iteration and one read happens after an agent has mutated it, the second read will silently see the wrong value and any log line downstream of that read is a proxy, not the property. In `ralph.sh`, the active bead id was captured once at iteration top and again after the agent ran; the agent had called `bd close` in between, so every successful iteration logged `bead=unknown`. Fix: one snapshot per iteration, reuse the variable. Applies to any loop that queries the same external tool around an agent invocation.
