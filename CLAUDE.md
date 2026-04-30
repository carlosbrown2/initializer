# Project Rules

This is the **initializer template** itself. The project under development is the template — the ralph loop, the kickoff prompt, the hook installer, the registers, and the skill files that future projects are bootstrapped from.

## Architecture

- `project-kickoff-prompt.md` — the phase-by-phase outcome contract for any project bootstrapped from this template.
- `scripts/ralph/ralph.sh` — the long-running agent loop. Picks a ready bead, runs the agent, re-runs the verification gate in bash on BEAD_DONE, derives confidence from observed signals (gate result, diff size, touched hooks/CLAUDE.md, retry count), auto-lands if policy allows.
- `scripts/ralph/prompt.md` — the per-iteration system prompt the loop feeds the agent.
- `scripts/hooks/install.sh` — installs the pre-commit chain (bead-type gate, rubric-edit guard, scope enforcement, register integrity + symbol-refs, review artifact validator, model-tag + pattern-citation validator, CLAUDE.md size guard) plus the commit-msg format hook and pre-push gate hook.
- `docs/failure-modes.md` and `docs/decision-register.md` — the two registers that every register-integrity hook parses.
- `docs/skills/` — domain skill files. `review-rubric.md` ships as a starter that each project refines in Phase 1; `harness-constraints.md` documents the inherited harness invariants (the five patterns the template's own development surfaced).

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

1. **During the bead:** `scripts/ralph/ralph.sh` runs the gate itself on BEAD_DONE via `scripts/ralph/lib.sh` `run_gate` (which sources the gate command from this file through `scripts/hooks/parsers.sh` `gate_command_extract`) and writes the real exit code (PASS/FAIL/SKIPPED) to `.last-gate-result` (gitignored). The agent emits no gate tag — a self-reported tag would be a prediction of the gate, not a measurement of it, and the pre-push hook existed largely to catch that exact bypass.
2. **On `git push`:** the pre-push hook installed by `scripts/hooks/install.sh` extracts this gate command, re-runs it, and blocks the push if the real exit code is non-zero. If `.last-gate-result` disagrees with the push-time re-run, the block message calls out the divergence — now meaning "tree or env changed between iteration and push" (an uncommitted edit, a flaky test, a version drift) rather than "agent lied about the gate."

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

## Harness Surface Bounds

The harness (`scripts/ralph/`, `scripts/hooks/`, `tests/hooks/`) is capped along four dimensions. A change that violates any earns explicit justification in the bead's notes, and the dimension being violated is the lens that focuses the justification.

1. **Pause-rate ceiling.** Aggregate `auto_land=false` rate across `scripts/ralph/confidence.log` stays at or below baseline. New `compute_confidence` downgrade sources or pause surfaces ship paired with a retirement or threshold-raise elsewhere — the rate is the bind, not any single axis. Bound by `tests/hooks/pause_rate_budget.bats`.
2. **Gate-clause count is fixed.** New harness checks land as functions in `scripts/hooks/parsers.sh`, wire into `scripts/hooks/install.sh`, and ride the existing `bats tests/hooks/` gate clause — gate-string length unchanged. A new top-level gate clause earns a separate justification naming the contract the existing clauses cannot absorb. Bound by `tests/hooks/gate_clause_count.bats`.
3. **Confidence-axis budget: one in, one out.** `compute_confidence` accepts a fixed number of axes. Adding one without retiring one bloats the function and dilutes per-axis signal-to-noise. A future maintainer should hold every axis in working memory and know what real-risk class it catches. Bound by `tests/hooks/compute_confidence_arity.bats`.
4. **Per-file and per-function line caps.** Harness shell files have line caps; no single function exceeds the cap that lets a maintainer hold it in memory. Cap-fail at commit triggers a `harness-pare:` bead whose DoD lists each function in the over-budget file, names its binding test or contract, classifies ritual vs. load-bearing, and pares ritual until under budget. Bound by `tests/hooks/budgets.bats`.

## Discovered Patterns

Project-specific patterns the agent surfaces during work land here under `### <title>` entries with `model:` tags and a binding artifact citation (path::symbol, `tests/...` reference, or a register row). Inherited template constraints are documented in `docs/skills/harness-constraints.md` and are not duplicated here.
