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

### Harness restraint (the small-set principle)

A common failure mode for harnesses like this one is sediment: a hook gets added the first time a bug shows up, never gets removed, and the chain accretes scar tissue that the model now competes against instead of leaning on. Initializer treats the harness as a small set on purpose. The rule is: **the failure-mode register catches a class once; we re-derive cleanly under the model that fixes it rather than carrying the bespoke hook forward.** A hook earns a slot in the pre-commit chain only when its failure class has demonstrably re-occurred and the gate (or the model) cannot already catch it. Speculative guards retire. The register row stays — it is the durable artifact — while the enforcement mechanism is allowed to collapse into a stronger gate, a stronger contract, or a stronger model as those become available.

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
- **Tunable autonomy** — Confidence routing is one bit derived from the verification gate (`PASS → HIGH`, anything else → `LOW`). The `auto-land:` policy maps that bit to "land", "pause on LOW", or "always pause", letting you dial human oversight from full (`auto-land: none`) to zero (`auto-land: all`). The agent self-escalates when it's stuck.
- **Structural enforcement** — Rules are enforced by hooks and gates, not just prompt instructions. If a constraint matters, it has a mechanical backstop. The pre-commit chain stays small on purpose (see **Configuration → Pre-commit hooks** for the exact set): structural enforcement is reserved for failure classes that have demonstrably re-occurred, not every theoretical Goodhart. The verification gate, the registers, and the model carry the rest.

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
    lib.sh                  # Pure routing functions (run_gate, compute_confidence, auto-land, retry state)
    prompt.md               # Per-iteration outcome contract for each agent session
  hooks/
    install.sh              # Pre-commit hook installer (6 hooks — see Configuration)
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
  hooks/                    # bats suite covering parsers and ralph routing
  gate/                     # bats suite for the verification gate itself (lives outside tests/hooks/ so the gate's self-test cannot recurse into the running gate)
  regression/               # Regression tests from bugs found during the project
```

### Runtime-generated files (gitignored)

These appear after the first ralph iteration and are **not** shipped with the template. Do not expect them to exist on a fresh clone:

- `scripts/ralph/archive.txt` — Per-bead progress log, one `## <date> - <bead-id>` block per BEAD_DONE. Append-only.
- `scripts/ralph/confidence.log` — One line per iteration with `bead`, `bead_done`, `confidence`, `policy`, `auto_land`, `gate_result`. Telemetry only — the routing decision is computed live in `ralph.sh` from `.last-gate-result`.
- `scripts/ralph/retry_state.json` — Written each iteration so the agent can see whether it's retrying a previously-failed bead and how many times.
- `.last-gate-result` — The **observed** gate exit (`PASS` / `FAIL` / `SKIPPED`) from the iteration-time re-run. Written by `scripts/ralph/lib.sh` `run_gate` after the agent emits `BEAD_DONE`, and re-checked by the pre-push hook (which calls out divergence between iteration-time and push-time results in its block message).
- `.current-bead-type` — `impl`, `review`, `pare`, `compound`, or `research`. Gate is fail-closed when a bead is in progress without this marker.
- `.current-bead-scope` — One file path per line; the scope-enforcement hook rejects commits outside this set.

## Configuration

- **Auto-land policy** — Set in `CLAUDE.md` under `## Confidence Routing`. Options: `all`, `high` (default for new projects), `none`. The shipped starter CLAUDE.md declares `high` so projects bootstrapped from the template pause on `LOW` confidence (any non-PASS gate) until the gate is strong enough to trust. The template's *own* CLAUDE.md uses `all` because the gate is fully fleshed out and the principal is the template author.
- **CLAUDE.md size limit** — Default 200 lines, enforced by pre-commit hook. Overflow goes to `docs/skills/`.
- **Max retries** — Default 3, set in `ralph.sh` (`_RALPH_MAX_RETRIES`).
- **Max iterations** — Default 30, passed as argument to `ralph.sh`.

### Pre-commit hooks (installed by `./scripts/hooks/install.sh`)

Six pre-commit hooks ship enabled, plus a commit-msg format hook and a pre-push gate hook. Each row is a failure class the register has seen at least once:

| Hook | What it enforces |
|---|---|
| CLAUDE.md size guard | Rejects commits pushing `CLAUDE.md` over 200 lines. Domain knowledge overflows to `docs/skills/` rather than letting the project-rules file accrete. |
| Bead type fail-closed gate | When a bead is in progress, `.current-bead-type` must exist and hold a valid value (`impl`/`review`/`pare`/`compound`/`research`). Closes the "skip the marker → no enforcement" bypass for the hooks below. Fail-closed on `bd` extraction errors too: if `bd list --status=in_progress --json` fails or returns non-parseable JSON, the commit is BLOCKED rather than silently treated as "no bead in progress". |
| Scope enforcement | `impl`/`pare`/`compound` beads must declare `.current-bead-scope`; commits outside the scope are rejected (infrastructure paths exempted; compound beads also get `CLAUDE.md`, `docs/skills/`, and `tests/regression/`). |
| Failure-mode register integrity | Every row in `docs/failure-modes.md` is single-line, its last cell holds an acceptable Status (`covered`/`proven-impossible`/`out-of-scope`), and every referenced check file exists on disk. |
| Decision register integrity | `docs/decision-register.md` has all baseline rows; every row is single-line with ≥5 columns and a last-cell Status of `bounded`/`ritual-bounded`/`agent-discretion`/`escalation-only`; every referenced bounding-mechanism file exists on disk. |
| CLAUDE.md model-tag validator | Every `### ` entry under `## Discovered Patterns` carries an anchored `model:` tag identifying its source model so the pattern can be retired or re-validated on model upgrade. |

A seventh hook, **dependency hallucination check**, ships commented out — uncomment after installing `dep-hallucinator` (or your preferred equivalent).

Two more hooks ship as separate git-hook files:

- **commit-msg format** — enforces `feat|fix|refactor|review|compound|research|docs|chore|test: ...` prefix, and when the message begins with `[`, enforces the full `[bead-id] - <title>` shape (regex sourced from `BEAD_ID_REGEX`).
- **pre-push** — re-runs the verification gate declared under `## Verification Gate` in `CLAUDE.md`. The gate includes `bash -n`, `shellcheck -x`, a `bd` version floor check, and the full bats suite under `tests/hooks/` and `tests/gate/`. The pre-push hook also reads `.last-gate-result` (written by `scripts/ralph/lib.sh` `run_gate` after the agent's bead-exit) and explicitly calls out divergence between the iteration-time and push-time gate runs in the block message.

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
