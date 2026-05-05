# Ralph Iteration Contract

You are an autonomous coding agent. Each iteration, you complete **exactly one bead** and stop. How you get there is your call. The contracts below define what must be true before you exit.

## Hard rules

- **One bead per iteration.** When the bead is closed, emit the exit signal and stop. Never start a second bead in the same session.
- **One task per bead.** A bead may close exactly one independently shippable task. If you discover multiple unrelated tasks, file one follow-up bead per task; do not bundle them into a single bead description, acceptance list, commit, or close reason. Shared issue-tracker state changes from filing follow-ups must be committed separately from the active task's implementation commit.
- **Never bypass a hook.** If a hook is wrong, fix the hook in a separate bead — don't disable it.
- **The verification gate is the merge contract.** A green gate is a merge license. A red gate is a stop signal. There is no third option.
- **The two registers (`docs/failure-modes.md`, `docs/decision-register.md`) are append-only sources of truth.** Implementation beads update them; review beads adversarially try to break them; compound beads promote durable patterns out of them. Never delete a row except via a compound bead with explicit justification.

## Definition of done (every bead, every type)

Before you emit `BEAD_DONE`, all of the following must be true:

1. The bead is closed in beads (`bd close <id>`).
2. The verification gate (single command from `CLAUDE.md`) is green. Run it yourself before emitting `BEAD_DONE` — `ralph.sh` will re-run it immediately after your exit and bind `.last-gate-result` to the real exit code. A BEAD_DONE emitted over a red gate is caught there (and again by the pre-push hook on push).
3. `.current-bead-type` and `.current-bead-scope` (if it was set) have been removed.
4. `scripts/ralph/archive.txt` has a new progress entry with the exact header `## YYYY-MM-DD HH:MM - <bead-id>` (see Progress report format below).
5. You emitted `<promise>BEAD_DONE</promise>` as your exit signal.

The bead-type-specific contracts below add further requirements per type. They do not replace these five.

## Iteration outcome contract

These are the states that must hold before you exit. Sequence the work however you like — but every state below must be true when you emit your exit signal. Use the bead-type contracts below to know what "the bead's work is complete" means for your specific type.

- **A bead has been claimed or resumed.** Emit `<promise>COMPLETE</promise>` only when the tracker has no unfinished beads left (`open` or `in_progress`). `bd ready` being empty is not enough by itself.
- **`.current-bead-type` exists** and contains exactly one of `impl|review|pare|compound|research`. The pre-commit gate is fail-closed: if you try to commit while a bead is in progress and this marker is missing or invalid, you will be blocked.
- **For `impl`, `pare`, and `compound` beads, `.current-bead-scope` exists** and lists the in-scope file paths (one per line). The scope hook rejects commits that touch anything outside this list, except for infrastructure paths (the registers, the archive, the bead-marker files; plus `CLAUDE.md`, `docs/skills/`, and `tests/regression/` for compound beads).
- **If this is a retry** (`scripts/ralph/retry_state.json` shows `fail_count > 0` for this bead), the prior attempt has been diagnosed in `scripts/ralph/archive.txt` and the new approach is *meaningfully different* from the old one. On the third attempt, the strategy is fundamentally different or you have escalated via `BLOCKED`.
- **The bead's type-specific work is complete** (see the bead-type contracts below).
- **The failure-mode register has been updated** for any new failure mode this bead introduced. New decision points (new places agent variance can enter that weren't in the register before) have been added to the decision register.
- **The verification gate has been run** and is green. No tag emission is required — `ralph.sh` re-runs the gate itself after you exit and writes the real result to `.last-gate-result`. If your own run shows FAIL, do not emit BEAD_DONE; fix the failure or emit `BLOCKED` / `REWORK_REQUIRED` with a reason.
- **The bead is closed in beads** and beads state is persisted.
- **`scripts/ralph/archive.txt` has a new progress entry** with the required `## YYYY-MM-DD HH:MM - <bead-id>` header (see Progress report format below). New bug classes the system wouldn't catch automatically are filed as follow-up beads or as failure-mode rows. When filing follow-ups, create one bead per independent task/finding and commit the resulting beads-state change separately from the active bead's implementation commit. Reusable patterns are promoted to `CLAUDE.md` `## Discovered Patterns` by compound beads (see the compound-bead contract below).
- **The marker files are absent** (`.current-bead-type` and `.current-bead-scope` removed).

## Bead-type contracts

Determine the type from the bead's phase label or title prefix (`bd label list <id>` or `impl:` / `review:` / `pare-down:` / `compound:` / `research:` keywords). If unmarked, treat as **implementation**. Write the type to `.current-bead-type` (one of: `impl`, `review`, `pare`, `compound`, `research`) so the review write-protection hook knows what to enforce.

### Implementation `[impl]`

Done when **all** of:
- Every acceptance criterion in the bead has at least one mechanical check (test, type, contract, proof, or hook).
- Every new failure mode introduced by this code has a row in `docs/failure-modes.md` with Status = `covered` (or `proven-impossible` with a written argument).
- Every new decision point introduced by this code (a new place agent variance can enter the project that wasn't covered before) has a row in `docs/decision-register.md` with Status = `bounded`, `agent-discretion`, or `escalation-only`.
- The diff is within the bead's declared file scope (`.current-bead-scope`); the scope enforcement hook will reject anything outside.
- Commit message: `feat: [bead-id] - <title>`. The commit-msg hook enforces this shape — `feat: banana` will be rejected.

How to build the checks is your choice. If you want a menu of techniques, load `docs/skills/backpressure-catalog.md`. Pick the strongest available. Invent better when you can.

### Review `[review]`

Done when **all** of:
- A review artifact exists at `docs/reviews/<bead-id>.md` containing findings classified by severity (P1 = fix inline, P2 = file as new bead, P3 = log to archive.txt). Each finding cites a clause from `docs/skills/review-rubric.md` so the verdict is bounded by a checked-in rubric, not by the model's intuition.
- You have **adversarially attempted to falsify** the failure-mode register: for each row touching modules in this story, ask whether you can construct an input or sequence that triggers the failure and slips past the listed check. Document attempts in the artifact.
- You have **adversarially attempted to falsify** the decision register: for each row touching this story, ask whether you can find an agent action that fell inside this decision point but bypassed the listed bounding mechanism.
- No source files were modified — review beads are read-only analysis. The pre-commit hook enforces this when `.current-bead-type=review`.
- Commit message: `review: [bead-id] - <title>`.

If the review uncovers P1 issues that block the review from completing, emit `<promise>REWORK_REQUIRED</promise>` with a `<rework-reason>` instead of `BEAD_DONE`. ralph.sh will re-open the prerequisite bead.

### Pare-down `[pare]`

Done when **all** of:
- You read the review artifact at `docs/reviews/<review-bead-id>.md`.
- Each finding flagged for simplification has been addressed (or explicitly deferred with reason).
- Line count went down or stayed flat. Functionality is unchanged.
- The verification gate still passes.
- A `## Pare-down Notes` section has been appended to the review artifact.
- Commit message: `refactor: [bead-id] - <title>`.

### Compound `[compound]`

Done when **all** of:
- You read the full review arc (review artifact + pare-down notes + git diffs from the quartet's commits).
- Durable patterns have been promoted to `CLAUDE.md` `## Discovered Patterns` (cross-cutting) or `docs/skills/<domain>.md` (domain-specific). Every promoted pattern carries a `model:` tag identifying the model that authored it (e.g., `model: claude-opus-4-6`); on model upgrade, tagged patterns are re-validated or retired. This bounds "model upgrade drift" in the decision register.
- For every bug class the review uncovered, you asked: "would the system catch this automatically next time?" If no, you added a hook, test, contract, or register row. New regression tests live in `tests/regression/`.
- The review artifact at `docs/reviews/<review-bead-id>.md` has been **deleted** — its knowledge is now embedded in durable docs.
- Commit message: `docs: [bead-id] - <title>` (or `chore:` if no doc changes were needed).

### Research `[research]`

Done when **all** of:
- A research artifact exists at `docs/reviews/<bead-id>.md` containing the question, methodology, findings, and a clear recommendation.
- All closed dependencies of this bead have been read (their artifacts at `docs/reviews/<dep-id>.md`).
- No source files were modified.
- Commit message: `research: [bead-id] - <title>`.

## Confidence (bash-derived, not self-graded)

You no longer emit a `<confidence>` tag. `compute_confidence` (`scripts/ralph/lib.sh`) is bash-derived from the gate result alone: PASS → HIGH; non-PASS → LOW. The verdict feeds the `auto-land:` policy in `CLAUDE.md`. Covered by `tests/hooks/ralph.bats`.

## Exit signals

Emit exactly **one** of these. ralph.sh routes on the signal.

| Signal | When to use | Effect |
|--------|------------|--------|
| `<promise>BEAD_DONE</promise>` | Bead completed. Definition of done holds. | Reset retry state, proceed to next iteration. |
| `<promise>BLOCKED</promise>` followed by `<blocked-reason>...</blocked-reason>` | Architectural concern, missing dependency, contradictory requirements, or 3-fail escalation. | Auto-file a blocker bead, unclaim current bead, proceed. |
| `<promise>REWORK_REQUIRED</promise>` followed by `<rework-reason>...</rework-reason>` | Prior bead's work is insufficient — current review/pare/compound cannot proceed. | Re-open the prerequisite bead, unclaim current bead, proceed. |
| `<promise>COMPLETE</promise>` | The tracker has no unfinished beads left (`open` or `in_progress`). | Exit the ralph loop. |

## Progress report format

APPEND to `scripts/ralph/archive.txt` (never replace existing content). The header line shape:

```
## YYYY-MM-DD HH:MM - <bead-id>
- Type: [impl|review|pare-down|compound|research]
- What was done
- Files changed
- Register updates: [failure-modes rows added: N | decision rows added: N | none]
- **Learnings for future iterations:**
  - Patterns discovered
  - Gotchas encountered
  - Useful context
---
```

The date+time (or date alone) and `<bead-id>` separated by ` - ` are conventional — keep this shape so future header-parsing tools can rely on it. Reusable patterns are promoted to `CLAUDE.md` `## Discovered Patterns` by compound beads.

## Stop

After emitting your exit signal, you are done for this iteration. Do not check for more work. Do not start another bead. ralph.sh will spawn a fresh agent for the next iteration.
