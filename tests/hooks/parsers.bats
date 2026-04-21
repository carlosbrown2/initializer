#!/usr/bin/env bats
# tests/hooks/parsers.bats — bats suite for scripts/hooks/parsers.sh
#
# Exercises every register-integrity parser against known-good and known-bad
# fixtures, including edge cases (escaped pipes, Unicode, 5-column rows,
# trailing whitespace, multi-line continuation rows). The parsers are the
# mechanism every other register-integrity contract rests on, so drift in
# them silently breaks the whole fail-closed chain.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/hooks/parsers.sh"
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# --- fm_status_check -----------------------------------------------------

@test "fm_status_check: accepts register with all valid statuses" {
  cat > "$TMPDIR_TEST/fm.md" <<'EOF'
# Failure-mode register
| Module | Failure mode | Category | Check | Status |
|--------|--------------|----------|-------|--------|
| mod-a  | boom         | correctness | tests/a.py | covered |
| mod-b  | crash        | correctness | n/a        | proven-impossible |
| mod-c  | drift        | operational | n/a        | out-of-scope |
EOF
  run fm_status_check "$TMPDIR_TEST/fm.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fm_status_check: rejects row with unknown status in last cell" {
  cat > "$TMPDIR_TEST/fm.md" <<'EOF'
| Module | Failure mode | Category | Check | Status |
|--------|--------------|----------|-------|--------|
| mod-x  | boom         | correctness | tests/x.py | maybe-later |
EOF
  run fm_status_check "$TMPDIR_TEST/fm.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"maybe-later"* ]]
}

@test "fm_status_check: rejects multi-line continuation row (last cell empty)" {
  cat > "$TMPDIR_TEST/fm.md" <<'EOF'
| Module | Failure mode | Category | Check | Status |
|--------|--------------|----------|-------|--------|
| mod-x  | boom         | correctness | tests/x.py | covered |
|        |              | ...continuation... |          |         |
EOF
  run fm_status_check "$TMPDIR_TEST/fm.md"
  [ "$status" -eq 1 ]
}

@test "fm_status_check: skips separator rows" {
  cat > "$TMPDIR_TEST/fm.md" <<'EOF'
| Module | Failure mode | Category | Check | Status |
|--------|--------------|----------|-------|--------|
| :---: | :---: | :---: | :---: | :---: |
| mod-a  | boom         | correctness | tests/a.py | covered |
EOF
  run fm_status_check "$TMPDIR_TEST/fm.md"
  [ "$status" -eq 0 ]
}

@test "fm_status_check: accepts trailing whitespace after status" {
  # Use printf to emit trailing spaces exactly on the data row
  printf '%s\n' \
    '| Module | Failure mode | Category | Check | Status |' \
    '|--------|--------------|----------|-------|--------|' \
    '| mod-a  | boom         | correctness | tests/a.py | covered   |' \
    > "$TMPDIR_TEST/fm.md"
  run fm_status_check "$TMPDIR_TEST/fm.md"
  [ "$status" -eq 0 ]
}

@test "fm_status_check: accepts Unicode in cells" {
  cat > "$TMPDIR_TEST/fm.md" <<'EOF'
| Module | Failure mode | Category | Check | Status |
|--------|--------------|----------|-------|--------|
| módulo | falha — ☃   | correctness | tests/a.py | covered |
EOF
  run fm_status_check "$TMPDIR_TEST/fm.md"
  [ "$status" -eq 0 ]
}

# --- fm_file_refs_check --------------------------------------------------

@test "fm_file_refs_check: accepts register whose refs exist on disk" {
  mkdir -p "$TMPDIR_TEST/tests"
  touch "$TMPDIR_TEST/tests/a.py"
  cat > "$TMPDIR_TEST/fm.md" <<'EOF'
| Module | Failure mode | Category | Check | Status |
| mod-a  | boom         | correctness | tests/a.py | covered |
EOF
  run fm_file_refs_check "$TMPDIR_TEST/fm.md" "$TMPDIR_TEST" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fm_file_refs_check: rejects register whose refs do not exist" {
  cat > "$TMPDIR_TEST/fm.md" <<'EOF'
| Module | Failure mode | Category | Check | Status |
| mod-a  | boom         | correctness | tests/missing.py | covered |
EOF
  run fm_file_refs_check "$TMPDIR_TEST/fm.md" "$TMPDIR_TEST" ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests/missing.py"* ]]
}

@test "fm_file_refs_check: accepts missing ref if staged for addition" {
  cat > "$TMPDIR_TEST/fm.md" <<'EOF'
| Module | Failure mode | Category | Check | Status |
| mod-a  | boom         | correctness | tests/new.py | covered |
EOF
  run fm_file_refs_check "$TMPDIR_TEST/fm.md" "$TMPDIR_TEST" $'tests/new.py'
  [ "$status" -eq 0 ]
}

@test "fm_file_refs_check: strips pytest-style ::test_name suffix when checking file existence" {
  mkdir -p "$TMPDIR_TEST/tests"
  touch "$TMPDIR_TEST/tests/a.py"
  cat > "$TMPDIR_TEST/fm.md" <<'EOF'
| Module | Failure mode | Category | Check | Status |
| mod-a  | boom         | correctness | tests/a.py::test_boom | covered |
EOF
  run fm_file_refs_check "$TMPDIR_TEST/fm.md" "$TMPDIR_TEST" ""
  [ "$status" -eq 0 ]
}

# --- dec_required_rows_check ---------------------------------------------

@test "dec_required_rows_check: accepts register with all baseline decisions" {
  cat > "$TMPDIR_TEST/dec.md" <<'EOF'
| Decision point | Where | Bounding | Enforcement | Status |
| Solution selection | x | y | z | bounded |
| Acceptance interpretation | x | y | z | ritual-bounded |
| Sampling variance | x | y | z | bounded |
| Verification truth | x | y | z | bounded |
| Scope creep | x | y | z | bounded |
EOF
  run dec_required_rows_check "$TMPDIR_TEST/dec.md"
  [ "$status" -eq 0 ]
}

@test "dec_required_rows_check: rejects register missing a baseline decision" {
  cat > "$TMPDIR_TEST/dec.md" <<'EOF'
| Solution selection | x | y | z | bounded |
| Acceptance interpretation | x | y | z | ritual-bounded |
| Sampling variance | x | y | z | bounded |
| Scope creep | x | y | z | bounded |
EOF
  run dec_required_rows_check "$TMPDIR_TEST/dec.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Verification truth"* ]]
}

# --- dec_row_structure_check ---------------------------------------------

@test "dec_row_structure_check: accepts row with >=5 columns and bounded status" {
  cat > "$TMPDIR_TEST/dec.md" <<'EOF'
| Decision point | Where | Bounding | Enforcement | Status |
|----------------|-------|----------|-------------|--------|
| Foo | x | y | z | bounded |
EOF
  run dec_row_structure_check "$TMPDIR_TEST/dec.md"
  [ "$status" -eq 0 ]
}

@test "dec_row_structure_check: rejects row with fewer than 5 columns" {
  cat > "$TMPDIR_TEST/dec.md" <<'EOF'
| Decision point | Where | Bounding | Status |
|----------------|-------|----------|--------|
| Foo | x | y | bounded |
EOF
  run dec_row_structure_check "$TMPDIR_TEST/dec.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"too few columns"* ]]
}

@test "dec_row_structure_check: rejects row with bad status" {
  cat > "$TMPDIR_TEST/dec.md" <<'EOF'
| Decision point | Where | Bounding | Enforcement | Status |
|----------------|-------|----------|-------------|--------|
| Foo | x | y | z | maybe |
EOF
  run dec_row_structure_check "$TMPDIR_TEST/dec.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad status"* ]]
}

@test "dec_row_structure_check: accepts all four valid statuses" {
  cat > "$TMPDIR_TEST/dec.md" <<'EOF'
| Decision point | Where | Bounding | Enforcement | Status |
|----------------|-------|----------|-------------|--------|
| A | x | y | z | bounded |
| B | x | y | z | ritual-bounded |
| C | x | y | z | agent-discretion |
| D | x | y | z | escalation-only |
EOF
  run dec_row_structure_check "$TMPDIR_TEST/dec.md"
  [ "$status" -eq 0 ]
}

@test "dec_row_structure_check: rejects multi-line continuation row (empty last cell)" {
  cat > "$TMPDIR_TEST/dec.md" <<'EOF'
| Decision point | Where | Bounding | Enforcement | Status |
|----------------|-------|----------|-------------|--------|
| Foo | x | y | z | bounded |
|     |   | ...continuation text... | | |
EOF
  run dec_row_structure_check "$TMPDIR_TEST/dec.md"
  [ "$status" -eq 1 ]
}

@test "dec_row_structure_check: accepts row with escaped pipes inside a cell" {
  # The cell "a \| b" should NOT increase the effective pipe count; the row
  # still has 5 real columns so it must pass.
  cat > "$TMPDIR_TEST/dec.md" <<'EOF'
| Decision point | Where | Bounding | Enforcement | Status |
|----------------|-------|----------|-------------|--------|
| Foo | a \| b | y | z | bounded |
EOF
  run dec_row_structure_check "$TMPDIR_TEST/dec.md"
  [ "$status" -eq 0 ]
}

@test "dec_row_structure_check: accepts Unicode in cells" {
  cat > "$TMPDIR_TEST/dec.md" <<'EOF'
| Decision point | Where | Bounding | Enforcement | Status |
|----------------|-------|----------|-------------|--------|
| Föo — ☃ | x | y | z | bounded |
EOF
  run dec_row_structure_check "$TMPDIR_TEST/dec.md"
  [ "$status" -eq 0 ]
}

@test "dec_row_structure_check: accepts trailing whitespace around status" {
  printf '%s\n' \
    '| Decision point | Where | Bounding | Enforcement | Status |' \
    '|----------------|-------|----------|-------------|--------|' \
    '| Foo | x | y | z |    bounded    |' \
    > "$TMPDIR_TEST/dec.md"
  run dec_row_structure_check "$TMPDIR_TEST/dec.md"
  [ "$status" -eq 0 ]
}

# --- dec_file_refs_check -------------------------------------------------

@test "dec_file_refs_check: accepts register whose refs exist" {
  mkdir -p "$TMPDIR_TEST/scripts"
  touch "$TMPDIR_TEST/scripts/h.sh"
  cat > "$TMPDIR_TEST/dec.md" <<'EOF'
| Decision point | Where | Bounding | Enforcement | Status |
| Foo | x | scripts/h.sh | z | bounded |
EOF
  run dec_file_refs_check "$TMPDIR_TEST/dec.md" "$TMPDIR_TEST" ""
  [ "$status" -eq 0 ]
}

@test "dec_file_refs_check: rejects register with missing ref" {
  cat > "$TMPDIR_TEST/dec.md" <<'EOF'
| Decision point | Where | Bounding | Enforcement | Status |
| Foo | x | scripts/missing.sh | z | bounded |
EOF
  run dec_file_refs_check "$TMPDIR_TEST/dec.md" "$TMPDIR_TEST" ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/missing.sh"* ]]
}

# --- claude_model_tags_check ---------------------------------------------

@test "claude_model_tags_check: accepts entry with model: tag" {
  cat > "$TMPDIR_TEST/CLAUDE.md" <<'EOF'
## Discovered Patterns

### Use anyio for async I/O
model: claude-opus-4-6
why: structured concurrency
EOF
  run claude_model_tags_check "$TMPDIR_TEST/CLAUDE.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "claude_model_tags_check: rejects entry without model: tag" {
  cat > "$TMPDIR_TEST/CLAUDE.md" <<'EOF'
## Discovered Patterns

### Use anyio for async I/O
why: structured concurrency
EOF
  run claude_model_tags_check "$TMPDIR_TEST/CLAUDE.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Use anyio for async I/O"* ]]
}

@test "claude_model_tags_check: ignores entries outside ## Discovered Patterns section" {
  cat > "$TMPDIR_TEST/CLAUDE.md" <<'EOF'
## Architecture

### Some component
(intentionally no model tag — outside the section)

## Discovered Patterns

### Tagged pattern
model: claude-opus-4-6
EOF
  run claude_model_tags_check "$TMPDIR_TEST/CLAUDE.md"
  [ "$status" -eq 0 ]
}

@test "claude_model_tags_check: does not count prose 'the model' as a tag" {
  cat > "$TMPDIR_TEST/CLAUDE.md" <<'EOF'
## Discovered Patterns

### Untagged pattern
prose that mentions the model but does not tag it.
EOF
  run claude_model_tags_check "$TMPDIR_TEST/CLAUDE.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Untagged pattern"* ]]
}

@test "claude_model_tags_check: detects untagged entry at end of section (no trailing heading)" {
  cat > "$TMPDIR_TEST/CLAUDE.md" <<'EOF'
## Discovered Patterns

### Dangling untagged pattern
no model tag, no trailing heading
EOF
  run claude_model_tags_check "$TMPDIR_TEST/CLAUDE.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Dangling untagged pattern"* ]]
}

@test "claude_model_tags_check: closes section on next ## heading" {
  cat > "$TMPDIR_TEST/CLAUDE.md" <<'EOF'
## Discovered Patterns

### Tagged
model: claude-opus-4-6

## After Patterns

### Not a pattern
no tag here, but outside section — should be ignored
EOF
  run claude_model_tags_check "$TMPDIR_TEST/CLAUDE.md"
  [ "$status" -eq 0 ]
}

# --- rubric_edit_check ---------------------------------------------------

@test "rubric_edit_check: rejects rubric still containing the starter disclaimer phrase" {
  cat > "$TMPDIR_TEST/rubric.md" <<'EOF'
# My Project Review Severity Rubric

This file is a starter rubric for projects bootstrapped from Initializer.

- **P1.correctness** — wrong result
- **P1.my-project-special** — domain-specific
EOF
  run rubric_edit_check "$TMPDIR_TEST/rubric.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"disclaimer"* ]]
}

@test "rubric_edit_check: rejects stub rubric with no clauses" {
  cat > "$TMPDIR_TEST/rubric.md" <<'EOF'
# My Project Review Severity Rubric

Header only, body intentionally blank — no clauses defined.
EOF
  run rubric_edit_check "$TMPDIR_TEST/rubric.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no clauses"* ]]
}

@test "rubric_edit_check: rejects rubric that copies starter clauses verbatim with no additions" {
  cat > "$TMPDIR_TEST/rubric.md" <<'EOF'
# My Project Review Severity Rubric

- **P1.correctness** — wrong result for spec-covered input
- **P1.contract-violation** — violates a checked-in precondition
- **P2.weak-test** — passes against the bug
- **P3.style** — convention nit
EOF
  run rubric_edit_check "$TMPDIR_TEST/rubric.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no project-specific clauses"* ]]
}

@test "rubric_edit_check: rejects rubric with the starter H1 header verbatim" {
  cat > "$TMPDIR_TEST/rubric.md" <<'EOF'
# Review Severity Rubric

- **P1.correctness** — wrong result
- **P1.my-project-special** — domain-specific
EOF
  run rubric_edit_check "$TMPDIR_TEST/rubric.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"starter header"* ]]
}

@test "rubric_edit_check: accepts rubric with a project-named header and a non-starter clause" {
  cat > "$TMPDIR_TEST/rubric.md" <<'EOF'
# My Project Review Severity Rubric

- **P1.correctness** — wrong result
- **P1.my-project-special** — domain-specific clause not in the starter set
EOF
  run rubric_edit_check "$TMPDIR_TEST/rubric.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- rubric_clauses_extract ---------------------------------------------

@test "rubric_clauses_extract: extracts only bold-marker clause definitions, ignores plain prose mentions" {
  cat > "$TMPDIR_TEST/rubric.md" <<'EOF'
# Project Rubric

- **P1.correctness** — definition
- **P2.weak-test** — definition

This prose mentions P1.correctness and P3.style without bold markers.

```
example fence: P3.docstring-drift
```
EOF
  run rubric_clauses_extract "$TMPDIR_TEST/rubric.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"P1.correctness"* ]]
  [[ "$output" == *"P2.weak-test"* ]]
  # Prose-only mentions and code-fence mentions are NOT extracted: only bold defs.
  [[ "$output" != *"P3.style"* ]]
  [[ "$output" != *"P3.docstring-drift"* ]]
}

@test "rubric_clauses_extract: missing rubric file returns 0 with empty output" {
  run rubric_clauses_extract "$TMPDIR_TEST/does-not-exist.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rubric_clauses_extract: deduplicates repeated definitions" {
  cat > "$TMPDIR_TEST/rubric.md" <<'EOF'
- **P1.correctness** — first def
- **P1.correctness** — accidentally repeated
EOF
  run rubric_clauses_extract "$TMPDIR_TEST/rubric.md"
  [ "$status" -eq 0 ]
  # Should appear exactly once
  count=$(echo "$output" | grep -c '^P1\.correctness$')
  [ "$count" -eq 1 ]
}

# --- review_artifact_clauses_check --------------------------------------

@test "review_artifact_clauses_check: accepts artifact citing only clauses defined in rubric" {
  cat > "$TMPDIR_TEST/rubric.md" <<'EOF'
# Project Rubric
- **P1.correctness** — wrong result
- **P1.my-special** — domain-specific
EOF
  cat > "$TMPDIR_TEST/artifact.md" <<'EOF'
Findings cite clauses from docs/skills/review-rubric.md.

**P1.correctness** — found a real bug.
**P1.my-special** — another real one.
EOF
  run review_artifact_clauses_check "$TMPDIR_TEST/artifact.md" "$TMPDIR_TEST/rubric.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "review_artifact_clauses_check: rejects artifact citing an invented clause" {
  cat > "$TMPDIR_TEST/rubric.md" <<'EOF'
# Project Rubric
- **P1.correctness** — wrong result
EOF
  cat > "$TMPDIR_TEST/artifact.md" <<'EOF'
**P1.correctness** — real
**P1.totally-made-up-clause** — invented finding
EOF
  run review_artifact_clauses_check "$TMPDIR_TEST/artifact.md" "$TMPDIR_TEST/rubric.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"P1.totally-made-up-clause"* ]]
  [[ "$output" != *"P1.correctness"* ]]
}

@test "review_artifact_clauses_check: lists every invented clause, not just the first" {
  cat > "$TMPDIR_TEST/rubric.md" <<'EOF'
# Project Rubric
- **P1.correctness** — wrong
EOF
  cat > "$TMPDIR_TEST/artifact.md" <<'EOF'
**P1.fake-one** — first
**P2.fake-two** — second
**P3.fake-three** — third
EOF
  run review_artifact_clauses_check "$TMPDIR_TEST/artifact.md" "$TMPDIR_TEST/rubric.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"P1.fake-one"* ]]
  [[ "$output" == *"P2.fake-two"* ]]
  [[ "$output" == *"P3.fake-three"* ]]
}

@test "review_artifact_clauses_check: adding a new clause to the rubric makes it valid (no separate registration)" {
  # Acceptance criterion from agent-template-c7x: defining a clause in the
  # rubric is the only step needed to make it citable.
  cat > "$TMPDIR_TEST/rubric.md" <<'EOF'
# Project Rubric
- **P1.brand-new-clause** — newly added
EOF
  cat > "$TMPDIR_TEST/artifact.md" <<'EOF'
**P1.brand-new-clause** — citing the brand new clause
EOF
  run review_artifact_clauses_check "$TMPDIR_TEST/artifact.md" "$TMPDIR_TEST/rubric.md"
  [ "$status" -eq 0 ]
}

@test "review_artifact_clauses_check: rejects when rubric has no clauses defined" {
  cat > "$TMPDIR_TEST/rubric.md" <<'EOF'
# Project Rubric (empty body, no clauses)
EOF
  cat > "$TMPDIR_TEST/artifact.md" <<'EOF'
**P1.correctness** — citing
EOF
  run review_artifact_clauses_check "$TMPDIR_TEST/artifact.md" "$TMPDIR_TEST/rubric.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no clauses"* ]]
}

@test "review_artifact_clauses_check: catches plain (non-bold) citation of an invented clause" {
  # Citations in artifacts often appear as **P1.foo** in headings but also as
  # plain `P1.foo` in surrounding prose. Both forms must be membership-checked.
  cat > "$TMPDIR_TEST/rubric.md" <<'EOF'
- **P1.correctness** — wrong
EOF
  cat > "$TMPDIR_TEST/artifact.md" <<'EOF'
The verdict is bounded by P1.fake-clause despite the clause not existing.
EOF
  run review_artifact_clauses_check "$TMPDIR_TEST/artifact.md" "$TMPDIR_TEST/rubric.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"P1.fake-clause"* ]]
}

@test "review_artifact_clauses_check: smoke against real rubric — all real clauses pass" {
  # Synthesize an artifact citing every clause currently defined in the project's
  # real rubric. This both exercises the full extract path and acts as a drift
  # detector: if the rubric ever loses a clause that an artifact relies on, the
  # smoke fixture itself becomes the canary.
  RUBRIC="$PROJECT_ROOT/docs/skills/review-rubric.md"
  CLAUSES=$(rubric_clauses_extract "$RUBRIC")
  [ -n "$CLAUSES" ]
  {
    echo "Findings cite clauses from docs/skills/review-rubric.md."
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      echo "**$c** — synthetic finding for smoke test"
    done <<< "$CLAUSES"
  } > "$TMPDIR_TEST/synthetic.md"

  run review_artifact_clauses_check "$TMPDIR_TEST/synthetic.md" "$RUBRIC"
  [ "$status" -eq 0 ]
}

# --- Smoke tests against the real project registers ---------------------
# These catch drift: if the real registers in this repo ever diverge from
# what the parsers accept, the CI gate fails loudly.

@test "smoke: real docs/failure-modes.md passes fm_status_check" {
  run fm_status_check "$PROJECT_ROOT/docs/failure-modes.md"
  [ "$status" -eq 0 ]
}

@test "smoke: real docs/failure-modes.md passes fm_file_refs_check" {
  run fm_file_refs_check "$PROJECT_ROOT/docs/failure-modes.md" "$PROJECT_ROOT" ""
  [ "$status" -eq 0 ]
}

@test "smoke: real docs/decision-register.md passes dec_required_rows_check" {
  run dec_required_rows_check "$PROJECT_ROOT/docs/decision-register.md"
  [ "$status" -eq 0 ]
}

@test "smoke: real docs/decision-register.md passes dec_row_structure_check" {
  run dec_row_structure_check "$PROJECT_ROOT/docs/decision-register.md"
  [ "$status" -eq 0 ]
}

@test "smoke: real docs/decision-register.md passes dec_file_refs_check" {
  run dec_file_refs_check "$PROJECT_ROOT/docs/decision-register.md" "$PROJECT_ROOT" ""
  [ "$status" -eq 0 ]
}

@test "smoke: real CLAUDE.md passes claude_model_tags_check" {
  run claude_model_tags_check "$PROJECT_ROOT/CLAUDE.md"
  [ "$status" -eq 0 ]
}

@test "smoke: real docs/skills/review-rubric.md passes rubric_edit_check" {
  run rubric_edit_check "$PROJECT_ROOT/docs/skills/review-rubric.md"
  [ "$status" -eq 0 ]
}
