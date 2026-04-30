# Upstream Harness Improvements

Changes made to the ralph-loop / confidence-routing / pre-commit harness in this downstream project that are candidates for back-port to the **initializer-template** repo. Each entry is a self-contained patch description: motivation, change, files, tests, and the diagnostic lens that surfaced it. Entries are append-only and dated; nothing here is project-specific.

The harness in question lives under `scripts/ralph/` and `scripts/hooks/` plus `tests/hooks/`. CLAUDE.md's `## Verification Gate` section and `## Confidence Routing` section pin the contract these scripts implement.

---

## Cross-cutting invariants

Four meta-rules bind the entries below as a coherent set rather than a pile of independent patches. A change violating any earns explicit justification in its own entry. Together they are the bind that keeps the harness improvements from spiraling into the same pattern saturation the 2026-04-29 runaway entry diagnoses — every entry below is readable as paying its rate, gate, axis, or surface cost explicitly. The harness is infrastructure, not a project artifact: it must stay an enabler, not become a liability that downstream projects bootstrapped from the template fight instead of use.

1. **Pause-rate ceiling.** Any change that adds a `compute_confidence` downgrade source or a new pause/blocking surface ships with (a) a firing-rate estimate against a recorded `confidence.log` sample, or a structural argument for why the trigger is conjunctive enough to be rare, and (b) a bracket test asserting the ceiling holds for representative iter shapes. The aggregate `auto_land=false` rate across the harness is the bind, not any single axis — additions are paid for by removals or threshold-raises elsewhere. The 2026-04-27 confidence-routing entry's three subtractions (drop `retry_count`, raise `diff_lines` 500→1200, scope `touched_claude_md` to edits outside `## Discovered Patterns`) are the budget the 2026-04-29 runaway entry's three additions (`loop_saturation` axis, governance-bead `>7d` forces LOW, integration-bead blocking) draw from; net firing rate against the same recorded log sample must stay at or below the prior baseline. A change that cannot demonstrate budget compliance is rejected; a change that overshoots earns a paired retirement of an existing pause source.

2. **Gate-clause count is fixed.** The verification gate string in CLAUDE.md is a tractable contract — adding top-level clauses inflates parse cost, multiplies CI runtime, and makes failure-attribution noisier (a single failing clause that conjuncts five checks is harder to triage than five named clauses, but five becomes fifty under append-only growth). New harness checks land as functions in `scripts/hooks/parsers.sh`, wire into the pre-commit chain via `scripts/hooks/install.sh`, and are tested under `bats tests/hooks/` — which is *already* a gate clause. The bats sweep absorbs new hook tests at constant gate-string length, so the gate scales with hook count without growing in clause count. A change that adds a new top-level gate clause earns a separate entry naming the contract the new clause covers and why the existing clauses (especially `bats`) cannot absorb it. Same shape applied recursively: a change to an existing clause's *contract* (e.g., extending the `bd` version pin to also pin a sibling tool) earns the same justification.

3. **Confidence-axis budget: one in, one out — or shrinkage with justification.** `compute_confidence` accepts a fixed number of axes. Adding an axis without retiring one bloats the function's surface and dilutes each axis's signal-to-noise; a future maintainer reading the function should be able to hold every axis in working memory and know what real-risk class it catches. The 2026-04-27 entry retires `retry_count` (axis fires on normal cadence after a silent-fail iter, no correctness signal once gate=PASS); the 2026-04-29 entry adds `loop_saturation` (axis fires on the runaway feedback loop, real-risk class). The 2026-04-30 pare bead (`agent-template-3st`) retires `loop_saturation` *without* a replacement: the runaway-loop's structural fixes — integration-pulse beads + pattern_citation_check — bind the failure class on their own, and a runtime heuristic detector did not pay for its surface cost. Net axis count therefore *shrinks* by one (4→3) — permitted because the retirement is paid for by named structural binds elsewhere, not by a new axis. A change that grows the axis count earns a separate entry naming why the new signal cannot fold into an existing axis (e.g., as a threshold tightening or as scoping to a more specific failure shape). A change that shrinks the axis count earns the same justification — the retired axis's failure class either becomes unmonitored or is now caught by a different mechanism, and the entry must say which.

4. **Harness surface is capped by line and function-size budgets.** The first three invariants bound *contract* dimensions of harness growth (pause sources, gate clauses, axes); this one bounds *implementation surface*. Per-file line caps and a per-function size cap land as `tests/hooks/budgets.bats`, absorbed by the existing `bats tests/hooks/` gate clause — gate-string length is unchanged. Cap-fail at commit triggers a `harness-pare:` bead whose DoD lists each function in the over-budget file, names its binding test or contract (per CLAUDE.md's "Pare-down test: where is the bound?" pattern, applied to harness code), classifies ritual vs. load-bearing, and pares ritual until under budget; if no ritual exists, refactors a load-bearing function into smaller helpers (e.g., decomposing a multi-axis routing function into one helper per axis); if both fail, raises the cap with documented justification in the bead's notes. Caps live in two registers: the template ships caps calibrated to the template's own harness (tight, since the template is small and clean); downstream projects inherit them at bootstrap and may raise them only via the harness-pare path. Cap-raises are themselves signal for the next pare review and become back-port data when the pattern recurs across projects. **Schedules are rejected:** a schedule fires whether or not the harness has grown, which is itself the ritual-layer pattern the discipline warns against — only growth triggers the review.

---

## 2026-04-27 — confidence-routing tuning to reduce false-positive human-review pauses

**Symptom.** On a 14-iteration `confidence.log` sample, ~50 % of `BEAD_DONE` iterations paused for human review (`auto_land=false` under `auto-land: high`). Spot-checking each pause against the underlying commit showed most were heuristic noise rather than real risk:

| Iter | Confidence | Cause | Real risk? |
|------|------------|-------|------------|
| 3 | MEDIUM | `retry_count > 0` carryover from a silent-fail iter | no |
| 4 | MEDIUM | same | no |
| 8 | MEDIUM | `touched_claude_md` — compound bead promoted a model-tagged pattern entry | no |
| 9 | MEDIUM | `touched_claude_md` — but no commit landed; signal read from prior commit | no, separate stale-HEAD bug |
| 11 | MEDIUM | `diff_lines > 500` — cassettes-pare bead, 909 lines | borderline |
| 13 | MEDIUM | `diff_lines > 500` — tree-impl bead, 1042 lines | borderline |
| 14 | LOW | `gate FAIL` | yes, real |

**Diagnostic lens.** For each MEDIUM/LOW pause, ask which of `compute_confidence`'s axes triggered it, then ask whether that axis catches a real-risk class or a normal-cadence class. Axes that fire on the normal cadence are noise; raise the threshold or scope them down.

### Change 1: drop `retry_count` axis from `compute_confidence`

**Why.** A silent-fail iter (no exit signal, the `else` branch in ralph.sh) bumps `_RALPH_FAIL_COUNT` without logging. The *next* successful iter snapshots that count *before* the BEAD_DONE branch resets it, then passes it as `retry_count` to `compute_confidence`, which downgrades to MEDIUM. The retry was a process signal — the agent struggled — but once the gate is green and the bead is closed, that struggle is amortized. There is no correctness signal in retry_count once gate=PASS.

**Patch.**
- `scripts/ralph/lib.sh:compute_confidence` — remove the 5th positional parameter and the `[[ "$retry_count" -gt 0 ]] && downgrades=...` line.
- `scripts/ralph/ralph.sh` — remove the `_RALPH_FAIL_COUNT_AT_ITER_START` snapshot (the comment block above the snapshot is no longer load-bearing), drop it from the `compute_confidence` call site, drop it from `_ralph_cleanup`'s `unset` list.
- `tests/hooks/ralph.bats` — collapse 5-arg `compute_confidence` calls to 4-arg; flip the `retry_count>0 → MEDIUM` test into a pin that the function ignores any 5th legacy arg (`compute_confidence "PASS" 100 false false 5` returns HIGH).

### Change 2: raise `diff_lines` threshold 500 → 1200

**Why.** The 500-line cut tripped on every Phase 3 module-impl bead in this project (config 626 lines, context_parser 549, cassettes-pare 909, tree-impl 1042). The threshold was being read as a "this is a normal-sized module" signal rather than "this is unusually large." The lib.sh comment already flagged this as "a heuristic baseline — calibrate against this repo's commit-size distribution."

**Recommendation for upstream.** The threshold itself is project-specific (depends on typical bead-size distribution); what matters is that **the template should ship a comment naming the calibration responsibility**, and that test boundaries should bracket the cut point with two adjacent tests (one just below, one just above) so a future `>` vs `>=` flip is caught mechanically.

**Patch.**
- `scripts/ralph/lib.sh:compute_confidence` — change `[[ "$diff_lines" -gt 500 ]]` to `[[ "$diff_lines" -gt 1200 ]]`; update the docstring's calibration note.
- `tests/hooks/ralph.bats` — bracket the cut with two tests: 1200 lines stays HIGH, 1201 lines downgrades to MEDIUM.

### Change 3: scope `touched_claude_md` to edits **outside** `## Discovered Patterns`

**Why.** Compound beads in this template's quartet pattern (impl → review → pare → compound) promote model-tagged entries to CLAUDE.md's `## Discovered Patterns` section. That section is by-design append-only output and redefines no rule the gate runs — a green gate against a Patterns edit is just as strong as a green gate against code. Edits to `## Invariants` or `## Verification Gate`, by contrast, can shift the gate's own definition in the same diff being evaluated, and that risk is what the axis is designed to catch.

**Patch.**
- `scripts/ralph/lib.sh` — add `claude_md_touched_outside_patterns` function. Reads `git show HEAD:CLAUDE.md` and `git show HEAD~1:CLAUDE.md`, strips the `## Discovered Patterns` section from both with awk (`/^## Discovered Patterns[[:space:]]*$/{f=1;next} /^## /{f=0} !f`), compares the rest. Bypasses unified-diff parsing entirely so hunk-header offsets and section reordering are handled trivially. Edge cases (file added, file deleted, no parent commit, no change) all explicitly handled.
- `scripts/ralph/ralph.sh` — replace inline `grep -qx CLAUDE.md` with the function call.
- `tests/hooks/ralph.bats` — 7 new tests using a temp git repo: pattern-only edit returns false (the compound-bead happy path); `## Invariants` edit returns true; `## Verification Gate` clause edit returns true; no-CLAUDE-change returns false; file-added returns true; file-deleted returns true; smoke against the live repo asserts only the boolean shape.

**Style invariant this depends on.** CLAUDE.md uses `## ` for top-level sections and `### ` for pattern entries inside `## Discovered Patterns`. The awk regex relies on that exact convention; if the template ever uses `## ` for nested entries, the strip silently mis-bounds.

### Change 4: log the actual bead worked on (`bead=<id>`) instead of `bead=unknown`

**Why.** ralph.sh captures `_RALPH_ACTIVE_BEAD` from `bd list --status=in_progress` at iter start. After a `BEAD_DONE` lands in iter N, the bead is closed; iter N+1 starts with no in-progress bead, so `_RALPH_ACTIVE_BEAD` is empty — the agent picks up a *new* bead via `bd ready` during the iter, and that bead's id is captured into `_RALPH_BEAD_ID`. The two confidence.log echo lines were using `${_RALPH_ACTIVE_BEAD:-unknown}`, which logged `bead=unknown` for every iter that started with no in-progress bead (almost all of them).

**Diagnostic lens.** The signature pattern: 12 consecutive `bead=unknown` BEAD_DONE entries in confidence.log with the bead-id absent on every successful iter, is the giveaway. A prior fix (visible in the comment block at ralph.sh ~line 198) corrected the *snapshot timing* but kept the wrong *variable name* in the log line.

**Patch.**
- `scripts/ralph/ralph.sh` — change two echo lines (the BEAD_DONE-with-confidence path and the no-confidence path) from `${_RALPH_ACTIVE_BEAD:-unknown}` to `${_RALPH_BEAD_ID:-unknown}`. The latter is set at the top of the iter (line ~227–241) from either `_RALPH_ACTIVE_BEAD` (if resuming) or `_ralph_bead_ready` (if starting fresh), so it always names the bead the agent will work on.

**Side benefit.** The `archive_schema_check` parser in `scripts/hooks/parsers.sh` requires every `bead_done=true` entry with a real bead id to have a matching `## <date> - <bead-id>` block in archive.txt. The prior `bead=unknown` mode meant the parser silently passed (it filters `bead=unknown` entries out before requiring archive entries). With real ids now in confidence.log, the parser starts actually enforcing the contract.

---

## 2026-04-27 — stale-HEAD detection on BEAD_DONE without a new commit

**Symptom.** `confidence.log` iter=9 (2026-04-24 16:57:05) emitted BEAD_DONE in a 28-min iter gap with no commit landed at HEAD. `compute_confidence` ran against the *prior* commit's diff (a compound-bead CLAUDE.md edit), saw `touched_claude_md=true`, downgraded to MEDIUM, and credited the iter to the wrong work. The agent had emitted the BEAD_DONE tag without producing a commit — the contract violation went undetected because every per-iter measurement (`diff_lines / touched_hooks / touched_claude_md`) reads HEAD without verifying HEAD has *moved* since iter start.

**Diagnostic lens.** A bead's commit-msg hook constrains the shape of every successful close (`<convtype>: [bead-id] - <title>`); the *absence* of a commit on a BEAD_DONE iter is the failure shape those measurements cannot detect because they are stateless reads of HEAD. The fix is paired observation — one read of `git rev-parse HEAD` at iter start, one at the decision point — and assert movement when BEAD_DONE was emitted. Observation, not prediction: no agent self-report tag closes the loop because the agent already self-reported BEAD_DONE incorrectly.

### Change 1: `compute_head_unchanged_for_bead_done` helper + ralph.sh wiring + log signal

**Why.** Two layers are independently necessary: (i) the *detection* (HEAD did not advance during a BEAD_DONE iter) lives in the helper, where bats can drive it against a temp git repo without invoking the loop; (ii) the *consequence* (force `gate_result=FAIL` so confidence routes to LOW and the iter pauses) lives in the loop's grading branch, where it shares context with the rest of `compute_confidence`'s inputs. Splitting the two lets a future change keep the same detection but route it differently (e.g., ESCALATE instead of FAIL) without touching the helper.

**Patch.**
- `scripts/ralph/lib.sh` — add `compute_head_unchanged_for_bead_done`. Takes pre-iter SHA and post-iter SHA; returns 0 (no movement) / 1 (commit landed). Intentionally narrow: it does not know *why* HEAD didn't move, only that it didn't.
- `scripts/ralph/ralph.sh` — capture `git rev-parse HEAD` into `_RALPH_HEAD_AT_ITER_START` before the agent runs; on BEAD_DONE detection, re-read HEAD, call the helper, and on `unchanged=true` force `gate_result=FAIL` plus emit `stale_head=true` into the confidence.log line.
- `docs/failure-modes.md` — new row binding the `stale_head=true` log signal to the FAIL routing so the contract is documented in the same register the rest of the gate uses.
- `tests/hooks/ralph.bats` — helper returns 0 when HEAD moved in a temp repo; returns 1 when HEAD is stale; integration test that a stub agent emitting BEAD_DONE without committing is forced to FAIL.

**Side-channel benefit.** The `stale_head=true` field is the operator-facing signal in confidence.log: a future audit looking for "iter that graded the wrong bead" can grep the log directly rather than cross-correlate `git log` against confidence.log timestamps. Visible in the recent log around iter=5 (2026-04-28T17:38:46) and iter=14 (2026-04-29T11:51:22) where `stale_head=true gate_result=FAIL` co-occur as designed.

### Recommendation for upstream

The change generalizes beyond `BEAD_DONE`-with-no-commit: any per-iter measurement that reads HEAD's diff without verifying HEAD has moved since iter start is reading the *prior* iter's work and grading the wrong bead. The fix shape — snapshot a volatile state at iter start, re-read at the decision point, refuse to grade if the state didn't move — is reusable. CLAUDE.md's `Snapshot volatile state once per iteration` pattern was filed to bind the principle for future adders.

---

## 2026-04-28 — emit bead type, title, description, and completed-work summary in ralph loop output

**Symptom.** Tailing `confidence.log` and reading the ralph loop's stdout left the operator blind to *what* the agent was working on or *what* it had just completed. Every entry was shape `iter=N bead=<id> bead_done=true confidence=HIGH …` — the bead id alone, no type, no title, no description, no commit subject. To reconstruct context the operator had to cross-reference `bd show <id>` and `git log <sha>` for every line. Two visibility losses compound:

| Surface | Was | Lost signal |
|---------|-----|-------------|
| iteration banner (stdout) | `Resuming: agent-template-cfc — <title>` (title only) | bead type (impl/review/pare/compound/research), full task description |
| confidence.log (audit trail) | `iter=N bead=<id> bead_done=true confidence=… auto_land=…` | bead type, title, what was actually committed |
| iteration footer (stdout) | `Iteration N complete. Continuing...` | what was completed in this iter |

**Diagnostic lens.** When `confidence.log` is the source of truth for "what happened in the loop," every field that requires a sidecar lookup is a visibility tax. The operator's mental model needs to fit on the line being read; if it doesn't, the audit shifts back into reactive `bd show`/`git log` whack-a-mole. Two derivability tests:

1. **Type derivability.** `bd show --json .issue_type` returns the bd-CLI taxonomy (`task` / `bug` / `feature`), which is uniformly `task` for everything in this repo's beadflow. The agent loop's logical taxonomy (per `prompt.md`'s "Bead-type contracts" section) is `impl` / `review` / `pare` / `compound` / `research`, encoded in the title prefix as `<type>:` or `Phase N <type>:`. The right type to display is the logical type, parsed from the title — not the CLI type.

2. **Completion derivability.** What was completed lives in HEAD's commit subject (constrained by the commit-msg hook to `<convtype>: [bead-id] - <title>`). Captured *after* stale-HEAD detection so a no-commit BEAD_DONE doesn't silently echo the *prior* bead's subject.

### Change 1: `_ralph_load_bead_meta` helper hydrates type/title/description from one `bd show --json`

**Why.** The existing `_ralph_bead_title` helper called `bd show --json` once for just the title. Adding type and description as separate `bd show` calls would triple the per-iter shell-out cost on a slow `bd`. A single helper that loads all three into module-scoped globals is cheaper and keeps the call shape uniform.

**Side bug.** While wiring this up, found that `_ralph_bead_title`'s jq path `.title // empty` silently produces empty output on `bd >= 0.49`, which returns `bd show <id> --json` as an array-of-one rather than an object (jq errors with "Cannot index array with string"). The fallback `bd show … | sed -n '2p'` parse was masking the real call. Both helpers now use `(if type == "array" then .[0] else . end).<field>` so a future bd downgrade or upgrade does not silently empty the banner.

**Patch.**

- `scripts/ralph/ralph.sh` — add `_ralph_load_bead_meta` (single `bd show --json` call, populates `_RALPH_BEAD_TYPE` / `_RALPH_BEAD_TITLE` / `_RALPH_BEAD_DESCRIPTION`). Derive logical type from title via `[[ "$_RALPH_BEAD_TITLE" =~ (^|[[:space:]])(impl|review|pare|pare-down|compound|research)[[:space:]]*: ]]`; fall back to `.issue_type` from JSON when no keyword matches. Fix `_ralph_bead_title`'s jq expression to handle both array and object responses. Add new globals to the cleanup `unset` list so sourcing the script does not leak state.

### Change 2: banner prints bead type, title, and description before agent runs

**Why.** The pre-run banner is the operator's first read of *what the agent is about to do*. A bare title is not enough when the bead's actual contract (DoD shape, scope, prereqs) lives in the description. Beads in this template's quartet pattern frequently encode `.current-bead-scope` rules and per-type DoD overrides in the description; surfacing it at iter start lets the operator catch a misclaimed bead before the agent runs for 30 minutes.

**Patch.**

- `scripts/ralph/ralph.sh` — replace the bare `Resuming: $id — $title` / `Current bead: $id — $title` lines with `[$type] — $title` plus a separate `Description: $desc` line. Drives off `_ralph_load_bead_meta`'s output so the banner and the log entry stay in sync (both read the same hydrated globals).

### Change 3: confidence.log entries carry `bead_type=`, `title=…`, and `completed=…`

**Why.** The log line is the only durable per-iter record. Adding the three fields means `tail confidence.log` answers "what happened this iter" without a sidecar `git log`. Each field is sanitized through `_ralph_sanitize_log_field` (collapse whitespace to single spaces, replace `"` with `'`, truncate to 160 chars with `...` marker) so a multi-line title or commit subject does not break the line-oriented grep parsers in `scripts/hooks/parsers.sh`.

**Backward-compat note.** `archive_schema_check` extracts the bead id with `grep -oE 'bead=[^ ]+'`. The new `bead_type=<word>` field does not contain `bead=` and so cannot be matched by that regex — adding it does not corrupt the parser. Title and completed values are wrapped in `"…"` and live at the end of the line, leaving the structured-field prefix intact for any future field-extracting parser.

**Patch.**

- `scripts/ralph/ralph.sh` — extend all five confidence.log echo points (BLOCKED / REWORK / ESCALATION / BEAD_DONE-with-confidence / BEAD_DONE-without-confidence). Each echo gains `bead_type=$_RALPH_BEAD_TYPE` and `title="$(_ralph_sanitize_log_field "$_RALPH_BEAD_TITLE")"`. The two BEAD_DONE branches additionally gain `completed="$(_ralph_sanitize_log_field "$_RALPH_COMPLETED_SUMMARY")"`.

### Change 4: capture HEAD's commit subject as `_RALPH_COMPLETED_SUMMARY`, gated on stale-HEAD

**Why.** The commit subject is the agent's own one-line answer to "what did this iter accomplish." It's enforced shape (`<convtype>: [bead-id] - <title>`) by the commit-msg hook makes it a stable summary surface. But on a stale-HEAD iteration (BEAD_DONE without a new commit, detected by `compute_head_unchanged_for_bead_done`), `git log -1 --pretty=%s` returns the *prior* bead's subject — exactly the cross-bead contamination class that the stale-HEAD detector exists to flag. So the summary is computed *after* stale-HEAD detection: if stale, replace with `(no new commit — stale HEAD)`; otherwise use HEAD's subject.

**Patch.**

- `scripts/ralph/ralph.sh` — add a `# Completed-work summary` block immediately after stale-HEAD detection and before gate-result. Stores into `_RALPH_COMPLETED_SUMMARY`; the variable is empty on non-BEAD_DONE iterations and populated on BEAD_DONE (with the stale-HEAD marker as fallback).

### Change 5: iteration footer prints bead context + completion summary on stdout

**Why.** Closing the visibility loop on the operator-facing stdout, not just the log file. After a BEAD_DONE iter the loop emits two indented lines — `<id> [<type>] — <title>` and `Completed: <subject>` — before the existing `Iteration N complete.` separator. On non-BEAD_DONE iterations (BLOCKED / REWORK / no-signal), the relevant status was already printed by those branches' own echoes, so the footer is gated on `_RALPH_COMPLETED_SUMMARY` non-empty to avoid duplicate noise.

**Patch.**

- `scripts/ralph/ralph.sh` — guarded `if [[ -n "$_RALPH_COMPLETED_SUMMARY" ]]` block right before the existing `echo "Iteration $_RALPH_I complete. Continuing..."`.

### Recommendation for upstream

The five changes are tightly coupled (shared variables, shared sanitization, shared backward-compat constraints) and should land as one bead in the template repo. Three structural decisions worth carrying:

1. **Logical type ≠ CLI type.** Whatever taxonomy the prompt encodes (in this template's case, the `impl/review/pare/compound/research` set) belongs in the banner and log, not bd's `task/bug/feature`. The derivation should live in the loop, not in the agent's self-report — the title prefix is a measurement, not a prediction.
2. **`bd show --json` shape compatibility.** Any new code that reads `bd show <id> --json` should use `(if type == "array" then .[0] else . end).<field>` to be robust to both bd <0.49 (object) and bd >=0.49 (array-of-one). Adding a one-liner test in `tests/hooks/ralph.bats` that asserts both shapes work would prevent future regressions.
3. **Free-form text in single-line logs.** Any field that can contain newlines, tabs, or quotes (titles, commit subjects, descriptions) goes through a sanitizer before reaching `confidence.log`. The line-oriented parsers in `scripts/hooks/parsers.sh` (`archive_schema_check`'s `grep -oE 'bead=[^ ]+'`) silently corrupt their output if a single field smuggles in a newline.

---

## 2026-04-29 — register-cited symbol resolution hook (close the layer beyond file-existence)

**Symptom.** The pre-commit register-integrity hook validates that path-shaped tokens in `docs/failure-modes.md` / `docs/decision-register.md` Check / Enforcement / Bounding-mechanism cells point to files that exist on disk. It does NOT validate that a cited `tests/test_<m>.py::test_<name>` suffix resolves to a real test function in that file. A pare-down that removes or renames a register-cited test silently breaks the row's bind — the row's coverage claim becomes a dangling reference, but CI passes because file-existence still holds.

The CLAUDE.md pattern `Register Check-cell citations bind the named symbol's existence-by-name, not just file existence` was filed earlier under the search-pare review precisely because the discipline was being held by the pare-down agent's *manual* cross-referencing — every row that cited `tests/test_X.py::test_Y` had to be read by hand against the actual test file before a delete or rename. That discipline scales until it doesn't; the structural bind closes the layer below `file-refs-check`.

**Diagnostic lens.** Surface a register row whose Check cell cites a `path/to/file.py::<symbol>` where the symbol does not exist in the file (delete the test, rename the helper, drop the constant). If the pre-commit hook still passes, the integrity layer is one level shallower than its prose claim. The same shape applies to any hook that validates a *path* token but treats the path's *contents* as opaque.

### Change 1: `register_symbol_refs_check` walks `<path>::<symbol>` tokens to definitions

**Why.** The existing `file-refs-check` is the right shape (extract token, validate against disk) but stops at the path. The natural extension — extract the `::<symbol>` suffix, grep the file for a defining form — closes the layer without changing the existing check's contract. Layered, not replacement.

**Patch.**
- `scripts/hooks/parsers.sh` — new `register_symbol_refs_check`. Walks both registers, extracts every `<path>::<symbol>` token, and asserts the symbol is defined in the file with one of: `def <symbol>(`, `async def <symbol>(`, `class <symbol>(` / `class <symbol>:`, or a module-level `<symbol> = …` / `<symbol>: <type> = …` assignment. Skips refs whose file is missing (the existing `file-refs-check` is responsible for that branch — composability rather than overlap) and skips gitignored files (no checked-in source to grep). On dangling refs, lists *every* offender so a single commit can fix them in batch.
- `scripts/hooks/install.sh` — wire `register_symbol_refs_check` into the pre-commit chain immediately after each register's existing `file-refs-check`. Order matters: `file-refs-check` reports missing files first; `register_symbol_refs_check` runs only against the residue where the file exists.
- `tests/hooks/parsers.bats` — coverage for accept (def / async def / class with bases / class without bases / module-level assignment / annotated module-level assignment), reject (cited test deleted, cited helper renamed, substring-match impostor where the cited `test_boom` only exists as `test_boom_extended`), and skip (file does not exist, gitignored file). Smoke tests against both real registers run under the verification gate, so the bats suite catches a future register edit that introduces a dangling ref before the commit-time hook fires on it.

**Style invariant this depends on.** The check uses grep against defining forms, not Python AST parsing — the registers may cite symbols in `.sh` / `.bats` / `.md` files where AST parsing doesn't apply. The grep regex relies on word-boundaries; the substring-impostor reject case (`test_boom` vs `test_boom_extended`) is the edge that distinguishes a regex-with-word-boundaries from a literal-substring scan.

### Recommendation for upstream

Three structural decisions worth carrying:

1. **Layer the check, don't replace it.** The existing `file-refs-check` keeps its contract; the new check runs *after* it on the residue. Layered checks compose; replacement checks couple a new failure shape to a working one and break both when edge cases surface.
2. **List every offender on failure.** Hooks that fail on the *first* dangling ref force the operator into a fix-commit-fix-commit loop. Hooks that list *every* offender allow a single batch fix. The bats coverage explicitly tests the "lists every dangling ref" shape, not just "fails on at least one."
3. **Skip the right things by name, not by accident.** Explicitly skip missing-file refs (delegated to `file-refs-check`) and gitignored files (no source to grep). Both decisions are documented in the bats suite as accept-cases so a future maintainer reading the test list sees the skip semantics, not just the accept/reject split.

This change is the structural enforcement of CLAUDE.md's `Register Check-cell citations bind the named symbol's existence-by-name` pattern. The pattern (prose) was the bind on the discipline; the hook is now the bind on the prose. Same direction as the broader theme of this doc: convert prose discipline into mechanical enforcement at the lowest layer that still allows clear failure messages.

---

## 2026-04-29 — runaway review → follow-up → pattern feedback loop in the quartet pipeline

**Symptom.** All 11 module quartets of this project (impl → review → pare → compound × 11, plus a cross-cutting e2e-replay quartet = 48 module beads) closed clean over 5 days, yet `bd ready` was not shrinking and operator-perceived progress had stalled. Census of the 11 open beads at the moment of audit:

| Open beads | Origin | Notes |
|---|---|---|
| 9 | `Phase 3 follow-up: …` | every one was spawned BY a review of an already-closed module — none is original phase scope |
| 1 | `ralph: log silent failures …` | already filed (`agent-template-y12`); harness hygiene |
| 1 | `Observe ralph loop for 20 impl beads; decide on research-phase split` | filed 2026-04-23, six days stale — the loop's own audit instruction, never picked up |

CLAUDE.md grew **10 910 B → 41 021 B (3.7×)** and **0 → 19 `## Discovered Patterns` entries** in the same window. About 8 of the 19 entries are meta-patterns *about how reviews find narrower binds* — i.e., the patterns reflexively make the next module's review stricter, which spawns more follow-ups, which compound into more patterns. No bead in the closed set asks "does the user's actual end-to-end use case work?"; every bead is module-internal test-tightening on already-passing code. Recent follow-up titles illustrate the marginal value: `cli AST AsyncAnthropic check rejects bare attribute reference`, `widen judge AST clamp check to reject arithmetic shapes`, `widen llm_client AST credential check to ast.Name and environb/getenvb`. Each binds a narrower regression shape; none binds a PRD-named acceptance criterion that wasn't already green.

**Diagnostic lens.** The quartet pipeline (impl → review → pare → compound) is *recursive in scope* with no negative feedback: each compound stage promotes patterns to CLAUDE.md → the next review reads tighter rules → spawns narrower-bind follow-ups → those compound into more patterns. Three derivability tests for the runaway state, all of which must fire concurrently to flag the failure mode (any one alone may be benign):

1. **Pattern saturation.** Plot `wc -c CLAUDE.md` and `grep -c '^### ' CLAUDE.md` against bead-close timestamps. If both monotonically grow and `## Discovered Patterns` doubles inside one phase, the pattern set is in append-only mode and nothing is being retired.
2. **Follow-up-vs-original ratio.** `bd list --status=open --json | jq` over titles starting with `Phase N follow-up:` (or analogous narrower-bind prefix) vs original-scope. If follow-ups are >70 % of `bd ready` while original scope is 0 open, the loop is operating on a tightening fixed point of already-closed work.
3. **Stale governance bead.** `bd list --status=open --json | jq '[.[] | select(.title | test("^(Observe|Audit|Decide|Triage)"))] | map(.created_at)'` against today. Any governance bead in `ready` >3 days is the loop's own warning siren, ignored.

The auditing methodology should ship as `scripts/ralph/audit-loop-saturation.sh` (or equivalent) so the operator can run a one-shot diagnostic when the loop *feels* stalled, with output matching the census table at the top of this entry: "what looks open, where it came from, what's stale."

### Change 1: each `## Discovered Patterns` entry must cite a binding artifact

**Why.** The pattern set is currently append-only because the only structural rule on it is `CLAUDE.md ≤ 200 lines` — a *count* bound, not a *content* bound. Bytes can grow 4× while line count stays flat. The pare-down discipline ("if no test binds the property, the layer is ritual") applies to the pattern set itself: a pattern with no checked-in test or register row that would regress on its removal is ritual prose. Without this gate, every compound bead leaves CLAUDE.md heavier and the next review stricter — the spiral's root.

**Patch.**
- `scripts/hooks/parsers.sh` — add `pattern_citation_check`: extracts every `### <title>` block under `## Discovered Patterns` and requires the body to contain at least one of (a) a `path/to/file.py::<symbol>` reference resolved by the existing `register_symbol_refs_check` machinery; (b) a `docs/failure-modes.md` row id (e.g., `row-42`); (c) a `tests/test_<module>.py::<test_name>` reference. Patterns without any citation fail the hook.
- `scripts/hooks/install.sh` — wire `pattern_citation_check` into the CLAUDE.md pre-commit chain.
- `tests/hooks/patterns.bats` — smoke test against the live CLAUDE.md (asserts every existing pattern carries a citation, becomes the migration deadline for the legacy pattern set); corrupted-pattern fixture asserts the hook fires.

**Style invariant this depends on.** Same as Change 3 in the 2026-04-27 entry: `## ` for top-level sections, `### ` for pattern entries inside `## Discovered Patterns`. The existing `claude_md_touched_outside_patterns` awk regex already pins this convention.

### Change 2: review beads file at most one follow-up; remainder go in row prose

**Why.** A review that finds N "test-binds-narrow-shape, row-prose-claims-class" issues currently spawns N follow-up beads, each weighted as P2 module work. The observed ratio in this project was ~1.5–2 follow-ups per module review, but each successive follow-up is a narrower regression shape than the last — diminishing margin. The fix is structural backpressure: review beads can promote *one* finding to a follow-up bead (the highest PRD-aligned one); remaining findings consolidate into the row's prose under a "narrower-shape variants" section, with the structural-shape regex written into the row's Check cell rather than spawned as a separate bead. Forces the reviewer to triage instead of fan-out.

**Patch.**
- `scripts/ralph/lib.sh` — add `count_followups_since_review` helper. Reads `bd list --json` filtered by `created_at > <last review-stage close in the same module>` and `title LIKE 'Phase % follow-up: <module> %'`. If >1 since the last review-stage bead in that module closed, log a `LOOP_SATURATION` line to `confidence.log` and force the next confidence call to MEDIUM.
- `prompt.md` (template-shipped) — the review-stage DoD adds: "at most 1 follow-up bead may be filed; remaining findings must be encoded as a prose update on the relevant `docs/failure-modes.md` row's Check cell, not as a new bead." This is a contract change on the review stage, not just a heuristic the agent can decline.
- `tests/hooks/ralph.bats` — assert `count_followups_since_review` correctly windows on the per-module review timestamp and assert the saturation downgrade fires at N=2.

### Change 3: mandatory integration-pulse bead between every K module quartets

**Why.** No bead in the closed set asked "does the user-facing CLI work end-to-end against the user's actual use case." The quartet pipeline is module-scoped; the cross-cutting `e2e-replay` quartet was the closest, and even that was a determinism property test, not a user-flow test. The fix is a periodic mandatory pulse: every K (=2 in this project's calibration) module quartets must be followed by an `integration-N` bead that drives the user-facing CLI against a recorded fixture and asserts the JSON output shape matches the PRD's expected output. Closing module quartet K+1 cannot start while `integration-K` is open in `bd ready`. Redirects pipeline progress toward shippability rather than ever-narrower fixture shapes.

**Patch.**
- `scripts/ralph/lib.sh` — add `integration_bead_blocking` predicate. Reads `bd ready --json` for any open bead with title prefix `integration-<n>:`; if present, the predicate returns the blocking bead's id and the loop refuses to claim any `Phase N (impl|review|pare|compound):` bead, surfacing the integration bead's id to the operator instead.
- `prompt.md` — phase-3 bead-creation guidance instructs the planner to interleave `integration-K` beads at quartet 2, 4, 6, …; each integration bead's DoD is "user invokes CLI against a fixture and the recorded output matches an expected JSON file."
- `tests/hooks/ralph.bats` — assert the predicate refuses module beads when an integration bead is open and accepts them when none is open.

**Recommendation for upstream.** `K=2` is project-specific (debate-mcts has 11 modules; smaller projects may want K=1, larger K=3-5). What ships in the template is the *predicate* and the prompt-side guidance, not the constant — same calibration-responsibility shape as the `diff_lines` threshold in the 2026-04-27 entry.

### Change 4: stale governance beads auto-surface above the iter banner

**Why.** `agent-template-uq6` ("Observe ralph loop for 20 impl beads; decide on research-phase split") was filed 2026-04-23 to ask exactly the question this audit just answered. It never got picked up — `bd ready` ranked it the same as everything else, and the loop preferred the next module quartet's review over a meta-question with no obvious "deliverable." A stale governance bead is the loop's own warning siren; ignoring it is the failure mode. The signal must reach operator visibility without depending on the agent self-prioritizing meta-work over module work.

**Patch.**
- `scripts/ralph/ralph.sh` — at iter start, after `_ralph_load_bead_meta`, add `_ralph_surface_stale_governance`. Greps `bd list --status=open --json` for titles matching `^(Observe|Audit|Decide|Triage|Review the loop)` with `created_at` >3 days. Prints them above the `Resuming:` / `Current bead:` banner under a `⚠ Stale governance:` header, with bead id, age in days, and title.
- `scripts/ralph/lib.sh` — add `governance_bead_max_age_days`. If the oldest stale governance bead is >7 days old, force the next `compute_confidence` call to LOW: the loop has been ignoring its own audit instruction for over a week, and that fact alone disqualifies HIGH confidence on whatever else just closed.
- `tests/hooks/ralph.bats` — assert the predicate matches `^Observe …` titled beads and ignores `^Phase 3 impl: …`; bracket tests around 7-day cut (7 days stays at the prevailing confidence, 8 days forces LOW).

### Change 5: `loop_saturation` axis on `compute_confidence`

**Why.** A runtime signal that the three derivability tests above are firing concurrently. `compute_confidence` already takes axes for `gate_result / diff_lines / touched_hooks / touched_claude_md`. Adding a fifth — `recent_followup_ratio`, the fraction of the last N closed beads with `Phase % follow-up:` titles — converts the fixed-point-of-self-tightening pattern into a downgrade signal the operator sees on the very next bead, not after weeks of accumulation.

**Patch.**
- `scripts/ralph/lib.sh:compute_confidence` — accept the new axis; downgrade once when `recent_followup_ratio > 0.6` over the last 5 closed beads AND no `Phase N impl:` or `integration-` bead has closed in that window. Update the docstring's calibration note: "saturation = the loop is operating on a fixed point of self-tightening reviews; pause for an operator audit."
- `scripts/ralph/ralph.sh` — compute the ratio at iter end via `bd list --status=closed --json | jq` over the last 5 closed beads. Echo it into `confidence.log` as `followup_ratio=N/5` so future audits can reconstruct the trajectory from the log alone.
- `tests/hooks/ralph.bats` — bracket tests around the 0.6 cut (3-of-5 follow-ups stays at the prevailing confidence, 4-of-5 follow-ups downgrades to MEDIUM); assert the `LOOP_SATURATION` log line fires on the downgrade path.

### Recommendation for upstream

The five changes target distinct stages of the same feedback loop and should not be split into independent template-repo beads:

1. **Pattern citation gate (Change 1)** stops new patterns from accumulating without a binding artifact — the *root* of the spiral.
2. **One-follow-up-per-review contract (Change 2)** caps fan-out at the review stage — the *amplifier* of the spiral.
3. **Mandatory integration pulse (Change 3)** redirects pipeline progress toward shippability — the *missing negative feedback*.
4. **Governance-bead surfacing (Change 4)** makes the loop's own warning sirens audible — the *missing operator interrupt*.
5. **Saturation confidence axis (Change 5)** detects the runtime signature of the failure mode — the *missing detector*.

A template-repo audit that ships any subset without the rest leaves the loop able to spiral on the remaining vector. Patterns without follow-up cap: still grows. Follow-up cap without integration pulse: still tightens already-passing tests, just slower. Integration pulse without pattern gate: still bloats CLAUDE.md. Saturation axis without integration pulse: detects the failure mode but provides no path out. The five-change set is the minimum viable bound on the failure class.

**Diagnostic lens for the next round.** When `bd ready` *feels* like it isn't shrinking but the iteration cadence and gate-pass rate look healthy, the workflow that surfaced this entry:

1. Compare open-bead origin: how many were filed in the original phase plan vs spawned BY a review of already-closed work? If the latter dominates, the pipeline is operating on a fixed point.
2. Plot CLAUDE.md byte size against time and count `## Discovered Patterns` entries. Monotonic growth + recent doublings = pattern set in append-only mode.
3. List the most recent N closed bead titles. If the suffixes are progressively narrower regression shapes against the same module surface (`AST X check rejects shape A` → `… rejects shape B` → `… rejects shape C`), each successive close is paying less and less margin.
4. Search `bd list --status=open` for governance-titled beads (`Observe`, `Audit`, `Decide`, `Triage`). The presence of one filed >3 days ago is the loop's own admission that the operator suspected this state — pick it up before any further module work.

The four steps together produce a one-page audit; if any one of them comes back negative, the loop is probably healthy and the perceived stall is anxiety, not state. All four positive is the runaway pattern this entry is named after.

---

## 2026-04-29 — harness surface-area budgets and trigger-based pare-down

**Symptom.** The harness (scripts/ralph/, scripts/hooks/, tests/hooks/) has grown to ~2070 lines of shell across 4 files and 30 functions. Today's largest function is 46 lines (`rubric_edit_check` in `parsers.sh`), with `archive_schema_check` at 45 and `claude_model_tags_check` at 41 — every function is well within holdable-in-memory bounds. The cross-cutting invariants above bound the *rate at which contracts grow* (pause sources, gate clauses, axes); they do not bound *implementation surface*. A change that retires one axis and adds another preserves the axis-budget invariant while still adding tens of lines to `lib.sh`. This entry installs the surface bound as a *forward-looking discipline*, not a crisis response: the harness today is healthy, and the right time to lock the bind is before drift takes it past holdable-in-memory, not after. Without a structural surface bound, the template eventually ships projects a tool downstream maintainers fight rather than use.

**Diagnostic lens.** Three derivability tests:

1. **Per-file line cap.** Each shell file has a fixed line budget; crossing it at commit is the trigger. File caps catch slow accretion of helpers and inline blocks that no single change would flag.
2. **Per-function size cap.** No single function exceeds the cap that lets a maintainer hold it in memory. The cap is set at today's largest function plus modest headroom (e.g., 60 lines when the largest function is 46) so the *next* add — not the current state — is what triggers the review. A function that approaches the cap is the natural target for decomposition into smaller helpers (e.g., a multi-axis routing function split into one helper per axis).
3. **Trigger-based pare-down, not scheduled.** Schedules fire whether or not the harness has grown — itself the ritual-layer pattern the project's pare-down rule warns against. Cap-fail at commit is the structural trigger; the response is a `harness-pare:` bead with a structured-review DoD, so the review has a real failure to investigate rather than a "look for things to remove" mandate.

### Change 1: `tests/hooks/budgets.bats` enforces per-file and per-function line caps

**Why.** A bats test under `tests/hooks/` is absorbed by the existing `bats tests/hooks/` gate clause — gate-clause count stays fixed (per the gate-clause invariant above). A separate top-level gate clause would inflate the gate string for what is structurally one more hook test.

**Patch.**
- `tests/hooks/budgets.bats` — one assertion per file (`wc -l < scripts/ralph/ralph.sh ≤ N`) plus one assertion per file for the longest function block (awk that walks function definitions, computes each block's length, asserts the max ≤ 80).
- `scripts/hooks/install.sh` — no change required; `budgets.bats` is run by the existing `bats tests/hooks/` sweep at commit and in the verification gate.

**Calibration responsibility (template vs. project).** Caps live in two registers:

1. **Template-ship caps.** The template ships `tests/hooks/budgets.bats` with caps calibrated to the template's own (small, clean) harness — tighter than any downstream project that has accumulated project-specific growth. Caps shipped at the *calibrating project's current values* silently ratify whatever growth that project has already accumulated, defeating the bind. The template's caps are the floor.
2. **Project caps.** A downstream project inherits template caps at bootstrap. As it grows the harness in response to project-specific failure modes, hitting a cap triggers a `harness-pare:` bead. A project that legitimately needs more surface raises its caps **with documented justification in the harness-pare bead's notes**; cap-raises are themselves signal for the next pare review.

### Change 2: trigger-based pare-down workflow with structured-review DoD

**Why.** Schedules are noise. A periodic sweep fires whether or not anything has grown — most cycles produce no findings or trivial ones, and ritual sweeps degrade into "look like we're paring." Cap-fail at commit is a precise signal; coupling the trigger to a structured-review DoD turns the cap fail from a blocker into useful work.

**Patch.**
- `prompt.md` (template-shipped) — bead-creation guidance: when `tests/hooks/budgets.bats` fails on a commit, file a `harness-pare-NNN` bead before continuing module work. The bead's DoD has structure:
  1. List every function in the over-budget file.
  2. For each, name the bats test or contract that binds it (CLAUDE.md's "Pare-down test: where is the bound?" pattern, applied to harness code; CLAUDE.md's "Contracts can be the bind, even when no test exercises them" pattern applies for layers held by spec citation rather than test).
  3. Classify each as ritual (no bind) or load-bearing (bound).
  4. Pare ritual until under budget. If no ritual exists, refactor a load-bearing function into smaller helpers (e.g., decomposing a multi-axis routing function into one helper per axis). If both fail, raise the cap with documented justification in the bead's notes.
- `docs/decision-register.md` (template-shipped row) — a row binds "harness surface bounded by `tests/hooks/budgets.bats`; cap-raises documented in `harness-pare-*` notes" so the discipline lives in the same register as the rest of the harness contracts and is mechanically tested by `register_symbol_refs_check` on cited helpers.

### Recommendation for upstream

Three structural decisions worth carrying:

1. **Caps are template-shipped, calibrated to the template's harness.** A downstream project bootstrapping from the template inherits them and tightens them as it finds working values. Caps that ship at the calibrating project's current values silently ratify accumulated growth and defeat the bind. The template-side maintainer's first responsibility on adopting this entry is naming the template's actual harness sizes and shipping caps at-or-below those values.
2. **Trigger-based pare-down, not scheduled.** Schedule-based sweeps fire whether or not the harness has grown — exactly the ritual-layer pattern the discipline is meant to prevent. Couple the pare review to a structural trigger (cap fail) so the review has a real failure to investigate. The shape generalizes: any periodic harness-hygiene work whose response is "look for things to fix" should be replaced with a structural trigger whose response is "fix the named thing."
3. **Cap-raises are diagnostic data.** When a downstream project raises caps repeatedly, the *template's design* is fighting that project's actual needs. The cap-raise log (visible in the `harness-pare-*` beads' notes) is back-port signal at the next manual template update — pattern across multiple downstream projects is what triggers a template-shape change. This is the inverse of the rest of this doc: most entries are project → template; cap-raise patterns are project → template *only when they recur*.

Combined with the three contract-surface invariants at the top of this doc, the harness has a four-dimensional bound on growth: pause-rate, gate-clause count, axis count, and implementation surface. A change that violates any of the four earns explicit justification in its own entry — and the dimension being violated is the lens that focuses the justification.

---

## Open follow-ups (filed as beads, not yet addressed)

Documented for the upstream template-repo so that a maintainer applying the above changes also knows what's left. (Stale-HEAD on no-commit BEAD_DONE was promoted out of this list when `agent-template-oza` landed — see the second 2026-04-27 entry above.)

1. **Silent failures don't log to confidence.log unless they escalate.** The `else` branch (no exit signal) only writes a log line when fail_count reaches max_retries. First and second silent failures leave no trace, so future audits cannot reconstruct the per-iter timeline from confidence.log alone. Fix: add one always-on log echo to the no-signal branch (e.g. `iter=N NO_SIGNAL bead=<id> fail_count=N/MAX`). (Tracked as `agent-template-y12` in this project.)

---

## Diagnostic methodology (for the next round)

When `confidence.log` shows a pause-rate that *feels* high, the workflow that surfaced the changes above:

1. Tail confidence.log; for each `auto_land=false` entry, identify which axis triggered. `gate_result=FAIL` means LOW (real); otherwise compute_confidence's PASS path was downgraded by one or more of `diff_lines / touched_hooks / touched_claude_md / retry_count`.
2. For each MEDIUM/LOW, correlate the iter's timestamp against `git log --pretty=format:'%h %ai %s' --shortstat` to find the commit at HEAD. Inspect `git show --numstat <sha>` to count diff lines and `git show --name-only <sha>` to see touched paths.
3. For each axis that fired, ask: does this catch a real-risk class, or does it fire on the normal cadence of how this project's beads are sized / structured?
4. Axes that fire on the normal cadence are heuristic noise — either drop the axis, raise its threshold, or scope it to a more specific failure shape. Axes that fire on real risk stay as-is.

Each axis change should land with bracket tests (just-below, just-above the new threshold) and a docstring-level calibration note so the next maintainer can repeat the lens.
