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

- Shell scripts: bash with `set -euo pipefail` (or `set -u` + explicit pipe handling where sourcing). Every script must be syntax-clean under `bash -n`.
- Parser logic in hooks uses awk with explicit column counts and escaped-pipe handling. Multi-line continuation rows in registers are rejected by design.
- Markdown registers use single-line rows with >= 5 columns. Bounding-mechanism cells that name a file must reference a file that exists on disk.

## Verification Gate

```
bash -n scripts/ralph/ralph.sh && bash -n scripts/hooks/install.sh && bash -n scripts/hooks/parsers.sh && bats tests/hooks/
```

The gate parse-checks every shell script the pre-commit chain depends on (`parsers.sh` is sourced by the generated hook at runtime, so a syntax error there silently breaks register integrity) and runs the full bats suite under `tests/hooks/` so parser and gate regressions surface mechanically. Every clause must exit non-zero on real failure with no soft-fail escape — do not append `|| true` anywhere, it binds to the whole `&&` chain and silently masks every prior clause (see `docs/failure-modes.md`). Markdown files (e.g. `scripts/ralph/prompt.md`) are not parseable as bash and must not be added to the chain.

The gate is enforced at **two points**, and both must agree before a push reaches the remote:

1. **During the bead (soft):** the agent runs the gate and self-reports via `<gate-result>PASS|FAIL</gate-result>`. `scripts/ralph/ralph.sh` parses the tag and persists it to `.last-gate-result` (gitignored) so downstream tools can compare.
2. **On `git push` (hard):** the pre-push hook installed by `scripts/hooks/install.sh` extracts this gate command, re-runs it, and blocks the push if the real exit code is non-zero. If `.last-gate-result` says PASS but the re-run fails, the block message calls out the divergence explicitly.

## Invariants

- The registers (`docs/failure-modes.md`, `docs/decision-register.md`) must parse cleanly under the integrity hooks in `scripts/hooks/install.sh`. Any edit to either register must preserve: single-line rows, >= 5 columns, valid status in the last cell, and existing paths for any path-shaped token in bounding-mechanism / enforcement columns.
- `CLAUDE.md` stays under 200 lines (size-guard hook). Domain knowledge goes to `docs/skills/`.
- Every `### ` entry under `## Discovered Patterns` carries a `model:` tag.
- No hook is ever bypassed with `--no-verify`. If a hook is wrong, fix the hook.

## Confidence Routing

auto-land: all

## Discovered Patterns

<!-- Patterns discovered during implementation — updated by compound beads -->
