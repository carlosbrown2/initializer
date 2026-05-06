# Project Rules

This is the **initializer template** itself. The project under development is the template — the ralph loop, the kickoff prompt, the hook installer, the registers, and the skill files that future projects are bootstrapped from.

## Architecture

- `project-kickoff-prompt.md` — the phase-by-phase outcome contract for any project bootstrapped from this template.
- `scripts/ralph/ralph.sh` — the long-running agent loop. Picks a ready bead, runs the agent, re-runs the verification gate in bash on BEAD_DONE, routes on the observed gate result (PASS → HIGH, anything else → LOW), and on auto-land runs the post-bead ritual (`git pull --rebase`, `bd sync`, push) from a clean committed tree.
- `scripts/ralph/prompt.md` — the per-iteration system prompt the loop feeds the agent.
- `scripts/hooks/install.sh` — installs the pre-commit chain (bead-type fail-closed gate, scope enforcement, failure-mode register integrity, decision register integrity, CLAUDE.md model-tag validator, CLAUDE.md size guard) plus the commit-msg format hook and pre-push gate hook.
- `docs/failure-modes.md` and `docs/decision-register.md` — the two registers that every register-integrity hook parses.
- `docs/skills/` — domain skill files. `review-rubric.md` ships as a starter that each project refines in Phase 1; `backpressure-catalog.md` is a menu of mechanical-check techniques implementation beads can pull from.

## Code Standards

- Shell scripts: bash with `set -euo pipefail` (or `set -u` + explicit pipe handling where sourcing). Every script must be syntax-clean under `bash -n` **and** pass `shellcheck -x`. `shellcheck` catches the class of quoting / subshell / word-split bugs `bash -n` does not — and because this is a template, every downstream project inherits the clean-bash default.
- Parser logic in hooks uses awk with explicit column counts and escaped-pipe handling. Multi-line continuation rows in registers are rejected by design.
- Markdown registers use single-line rows with >= 5 columns. Bounding-mechanism cells that name a file must reference a file that exists on disk.
- External tool versions that hooks parse output from (currently `bd`) are pinned in this file's `## Pinned Tool Versions` section and mechanically checked by the verification gate. A bd CLI format change can silently break every hook that reads its output; the pin turns that silent drift into a loud failure.

## Pinned Tool Versions

- `bd` (Beads CLI): **>= 0.3.0**. Gate clause `bd --version | grep -qE '^bd version ([1-9]|0\.([3-9]|[1-9][0-9]))'` fails if the installed version is older than 0.3.0 (the version whose `--json` output shape lib.sh and parsers.sh are built against). The regex matches the real `bd --version` output format (`bd version X.Y.Z ...`) and accepts `0.3.x`–`0.99.x` plus any `1.x+`.

## Verification Gate

```
bash -n scripts/ralph/ralph.sh && bash -n scripts/ralph/lib.sh && bash -n scripts/hooks/install.sh && bash -n scripts/hooks/parsers.sh && shellcheck -x scripts/ralph/ralph.sh scripts/ralph/lib.sh scripts/hooks/install.sh scripts/hooks/parsers.sh && bd --version 2>/dev/null | grep -qE '^bd version ([1-9]|0\.([3-9]|[1-9][0-9]))' && bats tests/hooks/ && bats tests/gate/
```

The gate parse-checks every shell script the pre-commit chain depends on (`parsers.sh` is sourced by the generated hook at runtime, so a syntax error there silently breaks register integrity), runs `shellcheck -x` across the full bash surface to catch quoting / subshell / word-split bugs that `bash -n` misses, verifies the `bd` CLI version against the pinned floor so a downstream-CLI format change surfaces as a gate failure rather than a silent hook no-op, and runs the full bats suite under `tests/hooks/` so parser and gate regressions surface mechanically.

Every clause must exit non-zero on real failure with no **soft-fail escape in a correctness chain** — this is the bug class that covers `|| true`, `|| :`, `|| 0`, `|| exit 0`, and any other trailer that swallows a non-zero exit. The name deliberately generalizes beyond the original `|| true` label because `||` precedence binds the trailer to the whole `&&` chain regardless of which no-op is on the right. Do not append any such trailer anywhere in the gate (see `docs/failure-modes.md`). Markdown files (e.g. `scripts/ralph/prompt.md`) are not parseable as bash and must not be added to the `bash -n` chain.

The gate is enforced at **two points**, and both must agree before a push reaches the remote:

1. **During the bead:** `scripts/ralph/ralph.sh` runs the gate itself on BEAD_DONE via `scripts/ralph/lib.sh` `run_gate` (which sources the gate command from this file through `scripts/hooks/parsers.sh` `gate_command_extract`) and writes the real exit code (PASS/FAIL/SKIPPED) to `.last-gate-result` (gitignored). The agent emits no gate tag — a self-reported tag would be a prediction of the gate, not a measurement of it, and the pre-push hook existed largely to catch that exact bypass.
2. **On `git push`:** the pre-push hook installed by `scripts/hooks/install.sh` extracts this gate command, re-runs it, and blocks the push if the real exit code is non-zero. If `.last-gate-result` disagrees with the push-time re-run, the block message calls out the divergence — now meaning "tree or env changed between iteration and push" (an uncommitted edit, a flaky test, a version drift) rather than "agent lied about the gate."

## Invariants

- The registers (`docs/failure-modes.md`, `docs/decision-register.md`) must parse cleanly under the integrity hooks in `scripts/hooks/install.sh`. Any edit to either register must preserve: single-line rows, >= 5 columns, valid status in the last cell, and existing paths for any path-shaped token in bounding-mechanism / enforcement columns.
- `CLAUDE.md` stays under 200 lines (size-guard hook). Domain knowledge goes to `docs/skills/`.
- Every `### ` entry under `## Discovered Patterns` carries a `model:` tag.
- No hook is ever bypassed with `--no-verify`. If a hook is wrong, fix the hook.
- Bead id shape lives in exactly one place per library: `BEAD_ID_REGEX` in `scripts/ralph/lib.sh` and `PARSERS_BEAD_ID_REGEX` in `scripts/hooks/parsers.sh`. A bats smoke test in `tests/hooks/parsers.bats` asserts the two values are equal byte-for-byte. Never inline the regex at a call site — reference the constant.
- `bd` CLI output is parsed only via `--json` + `jq`. Human-formatted output is not part of the bd contract and must not be a load-bearing parser input.

## Confidence Routing

The template itself ships `auto-land: high` as the safer default for every project bootstrapped from it. This template repo runs `auto-land: all` only because the gate is fully fleshed out and the human (you) is the only principal. Downstream projects should keep `high` until their gate is similarly strong.

auto-land: all

## Discovered Patterns

Project-specific patterns the agent surfaces during work land here under `### <title>` entries with `model:` tags and a binding artifact citation (path::symbol, `tests/...` reference, or a register row).
