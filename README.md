# Initializer

[![CI](https://github.com/carlosbrown2/initializer/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/carlosbrown2/initializer/actions/workflows/ci.yml)

A GitHub repo template that acts as an **initializer agent** — it sets up the development infrastructure, environment, and project scaffolding that subsequent coding agents will use. Built on the Ralph loop and Compound Engineering patterns with [Beads](https://github.com/steveyegge/beads) issue tracking.

Inspired by the [initializer agent pattern](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) from Anthropic's engineering team: a specialized first-session agent that creates the foundation (project rules, dev scripts, progress tracking, verification gates) so every subsequent agent session starts with clean context and clear direction.

`project-kickoff-prompt.md` does the heavy lifting of guiding the agent through this initialization, interacting with you the user to make all key decisions upfront.

Your creativity and thought are needed to use Initializer properly. You wouldn't want it any other way.

## Philosophy: outcome contracts, not procedures

Initializer is built around a single principle: **specify what must be true, not how to make it true.** The kickoff prompt describes outcome contracts the agent must satisfy at every checkpoint. Sub-step ordering is the agent's call.

This is the bitter-lesson play applied to engineering scaffolding. As models improve, prescriptive procedures become BLE-hobbling — they prevent the agent from finding shorter, better paths to the same outcome. Outcome contracts age with the model: a smarter agent will satisfy the same contract more efficiently, without requiring you to rewrite the prompt.

### The two registers (mechanical backbone)

Exhaustiveness is enforced through two live registers, both maintained by the agent and validated by pre-commit hooks:

- **`docs/failure-modes.md`** — Every failure mode the system can have, paired with a mechanical check that catches it. Status must be `covered`, `proven-impossible`, or `out-of-scope`. Negative-space proofs are required for every new module.
- **`docs/decision-register.md`** — Every place agent variance can enter the project (solution selection, sampling, scope creep, model upgrade drift, etc.) paired with the structural mechanism that bounds it. Status must be `bounded`, `agent-discretion`, or `escalation-only`. The decision register is how this template addresses LLM nondeterminism: not by eliminating sampling variance (impossible), but by funneling every agent choice through a falsifiable channel.

## How It Works

The initializer walks you through 5 phases. Each phase is an outcome contract — done when its conditions hold and you've approved them. The agent sequences sub-work however makes sense.

### The 5 Phases

1. **Spec** — Done when the PRD, both registers, the review rubric, the verification gate, and the structural hooks all exist and you've approved them.
2. **Beads** — Done when every PRD acceptance criterion is covered by a bead, every bead has a declared file scope, and you've approved the dependency graph. Each story decomposes into the quartet `impl → review → pare-down → compound`.
3. **Implementation (Ralph Loop)** — Done when every bead is closed, every commit passed the verification gate, and both registers stayed complete. Each iteration is a fresh agent session that completes exactly one bead and stops.
4. **Holistic Review** — Done when an adversarial cross-cutting review has tried to falsify every claim in both registers, and either failed (good) or filed a bead per finding.
5. **Final Compound** — Done when every rule that mattered is enforced structurally (not in prose), every bug class has a regression test, and the kickoff prompt has been updated with anything the next project would benefit from.

### Key Properties

- **Fresh context per task** — Each bead runs in a new agent session. No context rot across long projects — memory persists through git (the registers, `CLAUDE.md`, `docs/skills/`, discovered patterns), not conversation history.
- **Built-in quality loop** — Every feature goes through a quartet: implement → review → simplify → learn. Quality is structural, not optional.
- **Self-improving codebase** — Compound beads feed discovered patterns back into project knowledge, tagged with the model that authored them so they can be retired or re-validated on model upgrade.
- **Tunable autonomy** — Confidence routing lets you dial human oversight from full (`auto-land: none`) to zero (`auto-land: all`). The agent self-escalates when it's stuck.
- **Structural enforcement** — Rules are enforced by hooks and gates, not just prompt instructions. If a constraint matters, it has a mechanical backstop. Nine pre-commit hooks ship enabled (a tenth — dependency hallucination — ships commented out), plus a commit-msg format hook and a pre-push gate hook. The pre-commit chain runs: a fail-closed bead-type gate, the rubric-edit guard, scope enforcement, both register integrity checks (each layered with `register_symbol_refs_check` for `path::symbol` citations), review/research write-protection, the review-artifact validator, the CLAUDE.md model-tag and pattern-citation validator, and the CLAUDE.md size guard.

## Quick Start

1. Click **"Use this template"** on GitHub to create a new repo from Initializer.

2. Install dependencies:
   ```bash
   # Beads CLI (issue tracking) — version 0.3.0 or later required; the verification gate pins it
   brew install beads          # or: npm install -g @beads/bd
   bd init

   # jq (used by ralph.sh and parsers.sh to parse bd --json output)
   brew install jq             # or: apt-get install jq

   # shellcheck (part of the verification gate; catches quoting / subshell bugs bash -n misses)
   brew install shellcheck     # or: apt-get install shellcheck

   # bats (runs tests/hooks/; part of the verification gate)
   brew install bats-core      # or: npm install -g bats

   # Pre-commit hooks (optional but recommended)
   ./scripts/hooks/install.sh

   # Dependency hallucination detection (optional)
   pip install dep-hallucinator   # or: npm install -g dep-hallucinator
   ```

3. Direct your agent to walk through `project-kickoff-prompt.md`. It guides the agent through the full workflow: spec (PRD), beads, implementation, and review.

## The Ralph Loop

Once initialization is complete, `ralph.sh` runs the implementation loop — each iteration spawns a fresh agent that completes exactly one bead:

```bash
# Run with Claude Code (default)
source scripts/ralph/ralph.sh

# Run with Amp
source scripts/ralph/ralph.sh --tool amp

# Limit iterations
source scripts/ralph/ralph.sh 50
source scripts/ralph/ralph.sh --tool amp 50
```

## What's Included

Files committed to the template:

```
project-kickoff-prompt.md   # The initializer — outcome contracts for setting up a project
CLAUDE.md                   # Skeleton project rules (filled in during Phase 1)
scripts/
  ralph/
    ralph.sh                # The Ralph loop — runs agents one bead at a time
    lib.sh                  # Pure routing functions (parse_confidence, auto-land, retry state)
    prompt.md               # Per-iteration outcome contract for each agent session
  hooks/
    install.sh              # Pre-commit hook installer (9 hooks — see Configuration)
    parsers.sh              # Register parser library sourced by both hooks and bats tests
docs/
  failure-modes.md          # The failure-mode register (created in Phase 1)
  decision-register.md      # The decision register (created in Phase 1)
  skills/
    review-rubric.md        # P1/P2/P3 severity rubric, cited by every review bead
    backpressure-catalog.md # Menu of correctness techniques (load on demand)
    *.md                    # Other domain-specific knowledge (loaded per-bead)
  reviews/                  # Review/research artifacts (created/deleted during triads)
tasks/                      # PRDs live here
tests/
  hooks/                    # bats suite covering parsers, gate, ralph routing, and harness-surface invariants (per-file/per-function line budgets, gate-clause count, confidence-axis arity, pause-rate ceiling)
  regression/               # Regression tests from bugs found during the project
```

### Runtime-generated files (gitignored)

These appear after the first ralph iteration and are **not** shipped with the template. Do not expect them to exist on a fresh clone:

- `scripts/ralph/archive.txt` — Per-bead progress log, one `## <date> - <bead-id>` block per BEAD_DONE. Machine-parsed by `archive_schema_check` in the verification gate.
- `scripts/ralph/confidence.log` — One line per iteration with `bead`, `bead_done`, `confidence`, `policy`, `auto_land`, `gate_result`. Authoritative source for the archive schema check.
- `scripts/ralph/retry_state.json` — Written each iteration so the agent can see whether it's retrying a previously-failed bead and how many times.
- `.last-gate-result` — The agent's self-reported `<gate-result>` tag from the last iteration; compared against the real gate exit on pre-push.
- `.current-bead-type` — `impl`, `review`, `pare`, `compound`, or `research`. Gate is fail-closed when a bead is in progress without this marker.
- `.current-bead-scope` — One file path per line; the scope-enforcement hook rejects commits outside this set.

## Configuration

- **Auto-land policy** — Set in `CLAUDE.md` under `## Confidence Routing`. Options: `all`, `high` (default for new projects), `none`. The shipped starter CLAUDE.md declares `high` so projects bootstrapped from the template pause on MEDIUM / LOW confidence until the gate is strong enough to trust. The template's *own* CLAUDE.md uses `all` because the gate is fully fleshed out and the principal is the template author.
- **CLAUDE.md size limit** — Default 200 lines, enforced by pre-commit hook. Overflow goes to `docs/skills/`.
- **Max retries** — Default 3, set in `ralph.sh` (`_RALPH_MAX_RETRIES`).
- **Max iterations** — Default 30, passed as argument to `ralph.sh`.

### Pre-commit hooks (installed by `./scripts/hooks/install.sh`)

| Hook | What it enforces |
|---|---|
| Bead type fail-closed gate | When a bead is in progress, `.current-bead-type` must exist and hold a valid value (`impl`/`review`/`pare`/`compound`/`research`). Closes the "skip the marker → no enforcement" bypass for the hooks below. Also fail-closed on `bd` extraction errors: if `bd list --status=in_progress --json` fails or returns non-parseable JSON, the commit is BLOCKED rather than silently treated as "no bead in progress". |
| Rubric-edit guard | Phase 1 completion check. Once any bead is in progress, `docs/skills/review-rubric.md` must no longer match the shipped starter (no starter disclaimer, no starter H1 header verbatim, at least one project-specific clause). Goes silent once the rubric has been refined. |
| Scope enforcement | `impl`/`pare`/`compound` beads must declare `.current-bead-scope`; commits outside the scope are rejected (infrastructure paths exempted; compound beads also get `CLAUDE.md`, `docs/skills/`, and `tests/regression/`). |
| Failure-mode register integrity | Every row in `docs/failure-modes.md` is single-line, its last cell holds an acceptable Status (`covered`/`proven-impossible`/`out-of-scope`), and every referenced check file exists. Layered with `register_symbol_refs_check`: every `<path>::<symbol>` token in a Check cell must resolve to a `def`/`async def`/`class`/module-level binding actually defined in that file (catches a pare-down that renames or deletes the cited symbol while leaving the file in place). |
| Decision register integrity | `docs/decision-register.md` has all baseline rows; every row is single-line with ≥5 columns and a last-cell Status of `bounded`/`ritual-bounded`/`agent-discretion`/`escalation-only`; every referenced bounding-mechanism file exists. Same `register_symbol_refs_check` layer applies to `<path>::<symbol>` tokens in Bounding-mechanism / Enforcement cells. |
| Review/research write-protection | When `.current-bead-type` is `review` or `research`, only `docs/reviews/` may change. |
| Review-artifact validator | Files in `docs/reviews/` (during a `review` bead) cite `docs/skills/review-rubric.md` and contain at least one `P[123].clause-name` severity marker, and every cited clause is defined in the rubric. Quote-safe iteration (filenames with spaces are handled). |
| CLAUDE.md model-tag + pattern-citation validator | Every `### ` entry under `## Discovered Patterns` carries an anchored `model:` tag **and** at least one binding-artifact citation (a `<path>::<symbol>` token, a `tests/...` path reference, or a mention of `docs/failure-modes.md` / `docs/decision-register.md`). Closes the "patterns can grow as prose alone" loophole that the 200-line CLAUDE.md cap (a count bound, not a content bound) cannot. |
| CLAUDE.md size guard | Rejects commits pushing `CLAUDE.md` over 200 lines. |

A tenth hook, **dependency hallucination check**, ships commented out — uncomment after installing `dep-hallucinator` (or your preferred equivalent).

Two more hooks ship as separate git-hook files:

- **commit-msg format** — enforces `feat|fix|refactor|review|compound|research|docs|chore|test: ...` prefix, and when the message begins with `[`, enforces the full `[bead-id] - <title>` shape (regex sourced from `BEAD_ID_REGEX`).
- **pre-push** — re-runs the verification gate declared under `## Verification Gate` in `CLAUDE.md`. The gate includes `shellcheck -x`, a `bd` version floor check, and the full bats suite. The pre-push hook also reads `.last-gate-result` (written by `ralph.sh` after its own bead-exit gate run) and explicitly calls out divergence between the iteration-time and push-time gate runs in the block message.

### Why not the `pre-commit` framework?

We install git hooks directly from `scripts/hooks/install.sh` rather than using the Python [pre-commit](https://pre-commit.com/) framework. The tradeoff:

- **For this template**: zero extra dependencies (no Python env needed just to commit), hook definitions are plain bash readable in the same file, and the install step is a single script. The failure-mode register can name exactly what each hook enforces.
- **Against this template**: projects already using `pre-commit` for other languages can't drop these hooks into their existing config. If that's you, wrap the generated hooks in a local `pre-commit` repo — each hook already `set -euo pipefail`s and exits non-zero on failure, which is the pre-commit contract.

## Credits

- [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) by Anthropic Engineering — the initializer agent pattern and shift-handoff philosophy that inspired this project's name and structure
- [The Ralph Loop](https://ghuntley.com/loop/) by Geoff Huntley — the original loop pattern Initializer is built around
- [Compound Engineering](https://every.to/source-code/compound-engineering-the-definitive-guide) by Every — the guide to making every unit of AI-assisted work compound into the next
- [Bitter Lesson Engineering](https://danielmiessler.com/blog/bitter-lesson-engineering) by Daniel Miessler — the "specify what, not how" framing that drove Initializer's outcome-contracts approach

## License

MIT
