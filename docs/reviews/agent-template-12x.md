# Review: cross-bead review of upstream-harness-improvements back-port (Tier 1-3)

Findings cite clauses from `docs/skills/review-rubric.md`.

Scope: cumulative diff across the 11 back-port beads named in agent-template-12x:
agent-template-65s, agent-template-nvd, agent-template-dvd, agent-template-a8g,
agent-template-slc, agent-template-6eo, agent-template-t81, agent-template-d92,
agent-template-vh5, agent-template-ebh, agent-template-7zb. Reading was against
HEAD (4 commits ahead of origin/main); per-bead diffs were sampled via `git log
--oneline` plus the live state of `scripts/ralph/`, `scripts/hooks/`,
`tests/hooks/`, `docs/`, and `CLAUDE.md`.

## Verdict

**No P1 findings.** All seven focus areas the bead description names are
substantially in compliance: variable-hygiene order is correct, every
`## Discovered Patterns` entry carries a citation the live hook accepts, the
gate clause count holds at 7/7, the axis count holds at 5/5 positionals and 4/4
downgrade-axis lines, the per-file caps hold (with caveats below), and
`register_symbol_refs_check` is wired AFTER each register's existing
file-refs-check per the composability rule.

Six P2 findings and three P3 findings below; all are filed inline as proposals
for follow-up beads (per the rubric's `## Adversarial review technique` §
"tightenings become P2 follow-ups, not in-scope work").

---

## Focus area 1 — Cross-bead variable hygiene

**No findings.**

Verified directly against `scripts/ralph/ralph.sh`:

- `_ralph_load_bead_meta` runs at line 308; `_ralph_surface_stale_governance`
  at line 319. Order matches the bead description's requirement.
- Stale-HEAD detection (lines 367–379) gates `_RALPH_COMPLETED_SUMMARY`
  computation: stale → "(no new commit — stale HEAD)" marker (line 374);
  fresh → `git log -1 --pretty=%s` (line 377). The bead-meta surfacing's
  `_RALPH_COMPLETED_SUMMARY` is correctly downstream of nvd's stale-HEAD
  detection.
- `_ralph_cleanup` (lines 14–39) unsets every new global from the four beads:
  - nvd: `_RALPH_HEAD_AT_ITER_START`, `_RALPH_HEAD_AT_BEAD_DONE`,
    `_RALPH_STALE_HEAD`, `_RALPH_STALE_HEAD_FIELD` ✓
  - d92: `_RALPH_BEAD_TYPE`, `_RALPH_BEAD_DESCRIPTION`,
    `_RALPH_COMPLETED_SUMMARY`, function `_ralph_load_bead_meta`, function
    `_ralph_sanitize_log_field` ✓
  - ebh: `_RALPH_GOVERNANCE_JSON`, function
    `_ralph_surface_stale_governance` ✓
  - 7zb: `_RALPH_FOLLOWUP_NUMER`, `_RALPH_FOLLOWUP_DENOM`,
    `_RALPH_FOLLOWUP_RATIO` ✓ (the local `_RALPH_RECENT_CLOSED_TITLES` and
    `_RALPH_HAS_PHASE_OR_INT` are unset at line 534 within the BEAD_DONE
    branch, which is the right scope.)

---

## Focus area 2 — Pattern-citation gate against live CLAUDE.md

**No findings.**

The five existing entries under `## Discovered Patterns` all contain a
citation the live `pattern_citation_check` (`scripts/hooks/parsers.sh:487`)
would accept:

| Entry (CLAUDE.md line) | Citation form | Token |
|---|---|---|
| Bind checks to the property (L58) | docs/{failure-modes,decision-register}.md mention | `docs/decision-register.md` |
| One implementation, one library (L62) | tests/... path | `tests/hooks/parsers.bats` |
| Promote a ritual-bounded row (L66) | docs/{failure-modes,decision-register}.md mention | `docs/decision-register.md` and `docs/failure-modes.md` |
| Gate-clause ordering (L70) | tests/... path | `tests/hooks/` (in `bats tests/hooks/`) |
| Snapshot volatile state once (L74) | tests/... path | `tests/hooks/ralph.bats` |

The one entry that is closest to the line — Gate-clause ordering — passes
because the regex `(^|[^a-zA-Z0-9_/.-])tests\/[a-zA-Z0-9_]…` accepts
`bats tests/hooks/`. See **P2.weak-test** below for the adversarial concern.

---

## Focus area 3 — `retry_count` retirement orphan check

**One P2 and two P3 findings.**

Grep across `scripts/`, `tests/`, `docs/`, comments:

| Location | Reference | Verdict |
|---|---|---|
| `scripts/ralph/lib.sh:79,88,114` | docstring/comment context for the retirement | intentional, no action |
| `scripts/ralph/confidence.log:26` | historical log line title | log-line, no action |
| `scripts/ralph/archive.txt:196,351,353,355,358` | progress entries | append-only history, no action |
| `tests/hooks/ralph.bats:76-77` | explicit pin-test for legacy 5-arg shape | intentional contract test |
| `tests/hooks/compute_confidence_arity.bats:27-28,58-61` | stale axis-name comments | **P3.docstring-drift** |
| `tests/hooks/fixtures/confidence.log.sample:9` | column header still labels the 6th column `retry_count` | **P3.docstring-drift** |
| `tests/hooks/pause_rate_budget.bats:39` | variable name `retry` reading the 6th column | **P2.weak-test** (see below) |

**P2.weak-test** — `tests/hooks/pause_rate_budget.bats:39` reads the fixture's
6th column into a variable named `retry` and passes it through to
`compute_confidence` as the 5th positional. After agent-template-7zb retired
`retry_count` and replaced it with `recent_followup_ratio`, the fixture row
`retry-once|PASS|100|false|false|1` (line 39 of the fixture) now fires the
**new** axis by coincidence: integer `1` passes both the `r >= 0 && r <= 1`
range check and the `r > 0.6` cut at lib.sh:117, so the downgrade still
happens — but for a different reason than the test name suggests. The pause-
rate cap of 7 still holds, but it is held by a coincidence, not by a bind
on the new axis's intent. Proposed fix: rebuild the fixture against the new
axis (`recent_followup_ratio`), with one row at the 0.6 cut bracket on each
side, plus an explicit row that passes a legacy integer `5` to verify the
out-of-range branch silently no-ops.

**P3.docstring-drift** — `compute_confidence_arity.bats:27-28` and 58-61
both still say "$5 retry_count" and "retry_count > 0" in the calibration
notes, which is what the axis used to be, not what it is. Same drift in
`tests/hooks/fixtures/confidence.log.sample:9`'s column-header comment.
Both are stale annotations — the code under test is correct.

---

## Focus area 4 — Verification gate clause count (cross-cutting invariant #2)

**No findings.**

The gate string in `CLAUDE.md` (L28):

```
bash -n scripts/ralph/ralph.sh && bash -n scripts/ralph/lib.sh && bash -n scripts/hooks/install.sh && bash -n scripts/hooks/parsers.sh && shellcheck -x scripts/ralph/ralph.sh scripts/ralph/lib.sh scripts/hooks/install.sh scripts/hooks/parsers.sh && bd --version 2>/dev/null | grep -qE '^bd version ([1-9]|0\.([3-9]|[1-9][0-9]))' && bats tests/hooks/
```

Top-level `&&` separators: 6. Clauses: 7. Cap (per
`tests/hooks/gate_clause_count.bats:25`): 7. Compliant. The bats sweep absorbs
new hook tests, so subsequent additions land at constant clause count.

---

## Focus area 5 — `tests/hooks/budgets.bats` calibration (cross-cutting invariant #4)

**One P3 finding plus a calibration concern.**

Current per-file line counts vs caps:

| File | Lines | Cap | Headroom |
|---|---|---|---|
| `scripts/ralph/ralph.sh` | 599 | 600 | 1 |
| `scripts/ralph/lib.sh` | 391 | 400 | 9 |
| `scripts/hooks/parsers.sh` | 599 | 600 | 1 |
| `scripts/hooks/install.sh` | 651 | 700 | 49 |

Largest function: `pattern_citation_check` (parsers.sh) at 49 lines, cap 60,
11 lines headroom.

**P3.style** — The `ralph.sh` cap raise (550 → 600) is explicitly justified
in `tests/hooks/budgets.bats:30-37` with the bead id and the concrete
features that drove it. The `parsers.sh` cap (600) bears no equivalent
justification comment in the test, even though `pattern_citation_check`
(agent-template-vh5) and `register_symbol_refs_check` (agent-template-a8g)
both grew the file recently. The cap-raise discipline is being applied
inconsistently — every raise is supposed to leave a paper trail visible at
the bind site (the test), not only in the back-port doc and archive.

**Calibration concern (not a P-rank, observation only):** ralph.sh and
parsers.sh both have 1-line headroom. The next single-statement add to either
file fails `budgets.bats` at commit and triggers a `harness-pare:` bead. This
is the documented design ("the next add — not the current state — should
trigger the harness-pare review" — `budgets.bats:62`), but in practice 1 line
is so tight that a docstring expansion can trip the cap. A future entry could
either widen the headroom (paid for by a contract retirement elsewhere per
invariant #1) or leave it as-is and accept that small docstring edits will
trigger pares.

---

## Focus area 6 — Cross-cutting invariant compliance over the cumulative diff

**One P2 finding.**

- **Pause-rate ceiling (#1).** `tests/hooks/pause_rate_budget.bats` caps
  `auto_land=false` count on the fixture at 7. The fixture has 15 rows; the
  current count is 7 (1 gate-FAIL + 4 single-axis + 1 threshold-edge + 1
  two-axis collapse, per the test's docstring). The 11 back-port beads added
  three new pause sources: `loop_saturation` axis (7zb), `governance >7d`
  force-LOW (ebh), `stale_head=true` force-FAIL (nvd). The fixture predates
  all three and exercises none of them — the count of 7 holds vacuously
  against axes the fixture doesn't surface. **P2.weak-test** below.

- **Gate-clause count (#2).** Compliant (see Focus area 4).

- **Axis count (#3).** `compute_confidence_arity.bats` pins ≤5 positionals
  and ≤4 axis-lines. Live `compute_confidence` (`scripts/ralph/lib.sh:97`)
  uses 5 positionals and 4 axis-lines exactly. Compliant.

- **Surface budget (#4).** Per Focus area 5: all four files under cap.

**P2.weak-test** — `tests/hooks/fixtures/confidence.log.sample` doesn't
contain a row that exercises the new axes added by ebh / nvd / 7zb. The
pause-rate budget's "stay at or below 7" assertion is therefore a measurement
of the pre-back-port axes only. A future axis change that regressed pause
rate on, say, the `loop_saturation` axis would not surface here. Proposed
fix: extend the fixture with rows that explicitly fire each new axis (one
row per axis at the cut bracket, both sides) and re-baseline the pause-rate
cap against the extended fixture. The doc-prescribed budget compliance ("net
firing rate against the same recorded log sample must stay at or below the
prior baseline" — `docs/upstream-harness-improvements.md:13`) requires a
fixture that actually contains the axes' inputs.

---

## Focus area 7 — Failure-mode register integrity (a8g's `register_symbol_refs_check`)

**No structural findings; one adversarial probe finding (P2).**

Wiring verified in `scripts/hooks/install.sh`:

- Line 304: `fm_file_refs_check` runs first.
- Line 313: `register_symbol_refs_check "$FM_REGISTER" …` runs after.
- Line 362: `dec_file_refs_check` runs first.
- Line 371: `register_symbol_refs_check "$DEC_REGISTER" …` runs after.

Composability rule preserved: `file-refs-check` reports missing files;
`register_symbol_refs_check` runs only on rows whose file exists.

Existing register `<path>::<symbol>` citations: **zero**. Verified via
`grep -oE '(tests?|proofs|src|spec|docs|tasks|scripts|lib|pkg)/[a-zA-Z0-9_/.-]+\.[a-zA-Z0-9]+::[a-zA-Z0-9_]+'`
on both registers — empty output. The smoke tests at
`tests/hooks/parsers.bats:535-543` pass vacuously: no tokens, no missing
symbols. The check is fully defensive — its value is on a future commit that
adds a `path::symbol` token.

---

## Adversarial probes

### Probe 1 — `pattern_citation_check` shape vs. property gap (**P2.weak-test**)

The check (`scripts/hooks/parsers.sh:487-535`) requires one of three citation
forms. Its `tests/...` branch matches the regex
`(^|[^a-zA-Z0-9_/.-])tests\/[a-zA-Z0-9_][a-zA-Z0-9_/.-]*` — a *shape* match
on the path, not a *resolution* check. A future pattern body containing the
literal text `"tests/this-file-does-not-exist"` would pass the citation hook
without any binding artifact. This is the same proxy-vs-property gap the
CLAUDE.md "Bind checks to the property, not a proxy for it" pattern names —
applied to the citation hook itself.

Same gap on the `<path>.<ext>::<symbol>` branch: it matches shape, not
resolution. `register_symbol_refs_check` exists to resolve `::symbol` tokens,
but `pattern_citation_check` does not call it on the patterns' tokens. A
pattern citing `scripts/hooks/parsers.sh::ghost_function` would pass the
citation hook even though `register_symbol_refs_check` would reject the same
token in a register row.

Proposed fix: layer `pattern_citation_check` against
`register_symbol_refs_check` (for the `::symbol` branch) and against
`file_ref_is_valid` (for both other branches), so the citation is bound to
existence, not to the regex's shape acceptance. File as P2 follow-up.

Bead title proposal: "hooks: pattern_citation_check resolves cited paths to
existence-by-name (not just shape match)".

### Probe 2 — `register_symbol_refs_check` doesn't recognize bash function syntax (**P2.weak-test**)

The check accepts (parsers.sh:254-257) Python-shaped defining forms only:
`def name(`, `async def name(`, `class name(:`, `name = ...`, `name: type`.
The canonical file-type set the check loops over (`tests, proofs, src, spec,
docs, tasks, scripts, lib, pkg`) explicitly includes `scripts/` and `lib/`,
where bash code lives. A bash function defined as `compute_confidence() {`
matches none of the four patterns.

Concretely: a register row citing `scripts/ralph/lib.sh::compute_confidence`
would FAIL `register_symbol_refs_check` despite `compute_confidence` being a
real, well-known function in that file. The current registers happen to use
space-separation (`scripts/ralph/lib.sh compute_confidence`, not
`scripts/ralph/lib.sh::compute_confidence`) for bash symbols, which sidesteps
the gap by accident — a future operator who sees the explicit `::` form
recommended in the failure-modes register prose and tries to use it for a
bash symbol will hit a confusing reject.

The back-port doc acknowledges the file-type breadth ("the registers may
cite symbols in `.sh` / `.bats` / `.md` files where AST parsing doesn't
apply") but the implementation only adds support for the assignment form
(which works for `.bats` and `.md`), not for bash function definitions.

Proposed fix: add a fifth grep pattern `^${symbol_part}[[:space:]]*\(\)`
covering bash `name() {` syntax. File as P2 follow-up. Bead title proposal:
"hooks: register_symbol_refs_check recognizes bash function defining syntax".

### Probe 3 — failure-modes register row 31 vs. live state

Row 31 (the bead-context fields row added by d92) names three structural
failure modes. Each is bound by code currently visible in `lib.sh` /
`ralph.sh`. The smoke test `tests/hooks/ralph.bats` covers both bd JSON
shapes (object and array-of-one), the sanitizer, and all five log echo
branches — verified by `grep -nE '_ralph_load_bead_meta|_ralph_sanitize_log_field' tests/hooks/ralph.bats`
which lists tests on every named branch. No falsifying probe found.

### Probe 4 — `_RALPH_GOVERNANCE_JSON` failure handling

`scripts/ralph/ralph.sh:318` captures `bd list --status=open --json
2>/dev/null || echo "[]"`. On bd failure the variable is `[]` and both the
surfacing helper and `governance_bead_max_age_days` silently no-op. Failure-
mode register row 30 explicitly documents this as "best-effort visibility,
not a correctness gate" — the contract is honored, not violated. No finding.

### Probe 5 — Decision register Confidence row's coverage of new axes

Row "Confidence" (`docs/decision-register.md:19`) was broadened in 7zb to
mention `recent_followup_ratio` and the AND-suppression baked in at the call
site. The Bounding-mechanism cell names `compute_confidence` and
`claude_md_touched_outside_patterns`; the Enforcement cell enumerates the
ralph.bats coverage. Spot-check: the AND-suppressor ("baked in here by
passing 0 as the ratio") is at `ralph.sh:530-533` — `_RALPH_FOLLOWUP_RATIO=0`
unless `_RALPH_HAS_PHASE_OR_INT == 0`. The test enumeration in the row
matches what `ralph.bats` actually covers (legacy-arg-shape integer 5
ignored, 0.6/0.8 bracket, LOOP_SATURATION line emission). Tightly bound.

---

## Summary of follow-up beads to file

The reviewer recommends filing each of the following as a separate `[bug]` or
`[feature]` bead. None blocks the back-port; they are tightenings the
existing scope did not cover.

1. **P2.weak-test** — `tests/hooks/fixtures/confidence.log.sample` fixture
   rebuild against the post-back-port axes (loop_saturation, governance >7d,
   stale-HEAD). Pair with a re-baseline of the pause-rate cap.
2. **P2.weak-test** — `pattern_citation_check` resolves cited paths to
   existence-by-name (not just shape match). Layer against
   `register_symbol_refs_check` for `::symbol` and `file_ref_is_valid` for
   the other two forms.
3. **P2.weak-test** — `register_symbol_refs_check` recognizes bash function
   syntax (`name() {`) so `.sh` cites in either register actually validate.
4. **P3.docstring-drift** — `tests/hooks/compute_confidence_arity.bats`
   docstring updates: "$5 retry_count" → "$5 recent_followup_ratio";
   "retry_count > 0" → "recent_followup_ratio > 0.6 (with AND-suppression)".
5. **P3.docstring-drift** — `tests/hooks/fixtures/confidence.log.sample`
   header comment column-name update + variable-name fix in
   `pause_rate_budget.bats:39` (`retry` → `followup_ratio`).
6. **P3.style** — `tests/hooks/budgets.bats` add a comment block adjacent to
   the `parsers.sh` cap that names the bead(s) that drove the most recent
   raise, mirroring the discipline already applied to `ralph.sh`.

Bundling 4+5 into one bead is reasonable since both are docstring-only
changes against the loop_saturation rename. Bundling 1+2+3 would over-scope
a single review-followup bead — file each as its own.
