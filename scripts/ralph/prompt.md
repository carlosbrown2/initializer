# Ralph Agent Instructions

You are an autonomous coding agent. Each iteration, you execute ONE bead (story), then exit.

## Step 1: Orient

1. Read `scripts/ralph/patterns.md` — check **Codebase Patterns** before starting
2. Run `bd prime` then `bd ready` to find the next unblocked story
3. Run `bd show <id>` to read the full description and acceptance criteria
4. Claim it: `bd update <id> --status in_progress`

### Determine Bead Type

Inspect the bead title for a type prefix. Branch accordingly:

| Prefix | Bead Type | Description |
|--------|-----------|-------------|
| `[impl]` or none | **Implementation** | Build feature + tests (default) |
| `[review]` | **Review** | Multi-pass code review → artifact |
| `[pare]` | **Pare-down** | Simplify code from review findings |
| `[compound]` | **Compound** | Learning loop → update docs/skills |

If no prefix is present, treat the bead as **Implementation** (the default).

**After determining the bead type**, write it to `.current-bead-type` so pre-commit hooks can enforce constraints:
```bash
echo "<type>" > .current-bead-type   # one of: impl, review, pare, compound
```
This file is consumed by the review write-protection hook. Clean it up in Step 3 (Close).

### Check for Retry State

After claiming a bead, check if `scripts/ralph/retry_state.json` exists.
If it contains `fail_count > 0` for the same bead you're working on, this is a **retry**.

**On retry (fail_count 1–2):**
1. Review what was tried: run `git diff HEAD~1` and `git log -1 --oneline` to see the previous attempt
2. Run the verification gate to capture the current failure output
3. Write a diagnosis to `scripts/ralph/archive.txt`: what failed, why, what you'll try differently
4. Attempt a **meaningfully different approach** — do NOT repeat the same fix
5. If the error class is the same as the previous attempt (same test, same assertion), consider escalating early

**On 3rd attempt (fail_count = 2) — escalation required if gate fails:**
1. Try a **fundamentally different strategy** (e.g., different algorithm, different test approach, or revert and rethink)
2. If the quality gate still fails after this attempt:
   - Unclaim the bead: `bd update <id> --status open`
   - File a blocker: `bd create --title="BLOCKED: <bead-id> - <failure summary>" --type=bug --priority=1`
   - Write escalation notes to `scripts/ralph/archive.txt`
   - Emit `<promise>BEAD_DONE</promise>` (tells ralph.sh to move on)
   - Stop immediately — do NOT attempt further fixes

---

## Step 2: Execute (by bead type)

### Implementation Beads `[impl]`

Build the feature per acceptance criteria. Write tests for each criterion.

1. Implement the story per its acceptance criteria (from `bd show`)
2. Write tests covering each acceptance criterion
3. Run quality gate (defined in CLAUDE.md) — ALL tests must pass
4. Commit: `git add <files> && git commit -m "feat: [Story ID] - [Story Title]"`

### Review Beads `[review]`

Perform a multi-pass code review of the target file(s) specified in the bead description.

1. **Pass 1 — Structure**: Read target files. Note dead code, unclear naming, over-abstraction
2. **Pass 2 — Correctness**: Check invariants from CLAUDE.md, edge cases, off-by-ones
3. **Pass 3 — Simplification**: Identify code that can be removed, inlined, or merged
4. Write a review artifact to `docs/reviews/<story-id>.md` with findings organized by pass
5. Each finding should note: file, line range, category (dead-code/naming/invariant/simplify), severity (high/medium/low), and suggested fix
6. Do NOT modify source code — review beads are read-only analysis
7. Run quality gate — confirm no accidental changes broke tests
8. Commit: `git add docs/reviews/<story-id>.md && git commit -m "review: [Story ID] - [Story Title]"`

### Pare-down Beads `[pare]`

Simplify code based on findings from a prior review artifact.

1. Read the review artifact referenced in the bead description (e.g., `docs/reviews/<review-id>.md`)
2. Address findings by severity: high → medium → low
3. For each finding: apply the simplification, verify tests still pass
4. After all changes, run quality gate — ALL tests must pass
5. Commit: `git add <files> && git commit -m "refactor: [Story ID] - [Story Title]"`

### Compound Beads `[compound]`

Learning feedback loop — extract lessons from a review+pare cycle into durable project knowledge.

1. Read the review artifact referenced in the bead description
2. Extract patterns, invariants, or conventions that should be permanent
3. Update the appropriate target(s):
   - `CLAUDE.md` — new invariants, do-not rules, or discovered patterns
   - `docs/skills/*.md` — domain knowledge updates
   - `scripts/ralph/patterns.md` — codebase patterns for future iterations
4. Delete the review artifact (`docs/reviews/<review-id>.md`) — its knowledge is now embedded in durable docs
5. Run quality gate — confirm no accidental changes broke tests
6. Commit: `git add <files> && git commit -m "docs: [Story ID] - [Story Title]"`

---

## Step 3: Close

1. Close the issue: `bd close <id>`
2. Remove the bead type marker: `rm -f .current-bead-type`
3. Append progress to `scripts/ralph/archive.txt` (format below)
4. Emit a confidence signal for the completed bead:

```
<confidence level="HIGH|MEDIUM|LOW">One-line rationale</confidence>
```

Guidance:
- **HIGH** — All acceptance criteria met, tests pass, no ambiguity in implementation
- **MEDIUM** — Criteria met but with minor uncertainty (e.g., edge case coverage, interpretation of spec)
- **LOW** — Significant uncertainty remains (e.g., partial criteria, workaround applied, needs follow-up)

## Step 4: Stop

You are DONE for this iteration. Do NOT check for more stories. Do NOT start another story.

1. Emit the appropriate exit signal (see below)
2. If you emitted `BEAD_DONE`, run `bd ready` ONLY to check if all stories are finished.
   - If no more stories remain, ALSO reply with: `<promise>COMPLETE</promise>`
3. Output your progress report and stop immediately. The ralph loop will invoke you again for the next story.

**Exit signals — emit exactly ONE of these:**

| Signal | When to use | What ralph.sh does |
|--------|------------|-------------------|
| `<promise>BEAD_DONE</promise>` | Bead completed successfully | Reset retry state, proceed to next iteration |
| `<promise>BLOCKED</promise>` | Architectural concern, missing dependency, or external blocker prevents progress | Auto-file a blocker bead, unclaim current bead, proceed to next iteration |
| `<promise>REWORK_REQUIRED</promise>` | Prior bead's work is insufficient — current bead (review/pare/compound) cannot proceed | Re-open the prerequisite bead, unclaim current bead, proceed to next iteration |
| `<promise>COMPLETE</promise>` | `bd ready` returns no more work | Exit the ralph loop |

**When to use BLOCKED:**
- You discover an architectural issue that requires human decision-making
- An external dependency or service is unavailable
- The bead's requirements are contradictory or ambiguous and cannot be resolved from existing docs
- Always include a reason: `<promise>BLOCKED</promise>` followed by `<blocked-reason>description of the blocker</blocked-reason>`

**When to use REWORK_REQUIRED:**
- A review bead finds critical issues (P1) in the implementation that must be fixed before review can complete
- A pare-down bead finds the code is untestable or broken in ways the review didn't catch
- Always include a reason: `<promise>REWORK_REQUIRED</promise>` followed by `<rework-reason>description of what needs fixing</rework-reason>`

---

## Progress Report Format

APPEND to `scripts/ralph/archive.txt` (never replace existing content):

```
## [Date/Time] - [Story ID]
- Bead type: [implementation|review|pare-down|compound]
- What was done
- Files changed
- **Learnings for future iterations:**
  - Patterns discovered
  - Gotchas encountered
  - Useful context
---
```

If you discover a **reusable pattern**, also add it to `scripts/ralph/patterns.md`.

---

## Rules

- ONE bead per iteration — after completing it, STOP. Do not continue to the next bead.
- Commit frequently, keep all tests green
- Reuse existing infrastructure — do NOT rewrite what's already in the codebase
- Read patterns.md before starting
- Review beads are READ-ONLY — do not modify source code
- Pare-down beads require a prior review artifact — fail fast if missing
- Compound beads DELETE the review artifact after extracting knowledge
