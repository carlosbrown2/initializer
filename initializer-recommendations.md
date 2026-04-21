# Initializer — recommended changes

Audit of `carlosbrown2/initializer` against the 56 laws on lawsofsoftwareengineering.com, filtered through Bitter Lesson Engineering. BLE here is read as: dictate *what* must be true, not *how* to achieve it; mechanism in service of outcomes is welcome.

Two genuine findings, one tightenable-but-not-violating observation, and a nit.

---

## 1. Gate-bypass — `<gate-result>` is self-reported with no mechanical re-run

**Law:** Goodhart's Law. Also P1.gate-bypass in the repo's own review rubric.

**Where:** `scripts/ralph/ralph.sh` lines 313–319; `project-kickoff-prompt.md` line 197.

**What's wrong:** The repo's thesis is *"if a rule matters, it must be enforced mechanically"* (kickoff line 177), and the merge contract is stated plainly: *"A green gate is a merge license. A red gate is a stop signal. There is no third option"* (kickoff line 205, repeated in `prompt.md` line 9). But the one structural check on this contract is `grep -q '<gate-result>PASS</gate-result>'` against the agent's own output. `GATE_RESULT` is only logged (line 328); it is not wired into `AUTO_LAND`. The agent can emit a PASS tag without running the gate command, and ralph.sh will proceed. The kickoff prompt acknowledges this at line 197 (*"tag truth is the agent's self-report — which is why 'Verification truth' is `ritual-bounded`"*) and offers the fix in the same sentence (*"add a pre-push hook that re-runs the gate command"*) but does not ship it.

**Why BLE doesn't excuse this:** BLE-as-corrected says mechanism-for-outcomes is welcome. The outcome here (gate actually ran, actually passed) is quality-critical. A pre-push hook that re-executes the gate dictates nothing about how the agent arrived at the commit; it only confirms the merge-contract outcome.

**Recommended fix:** Add a `pre-push` hook (or an `after-agent` step inside `ralph.sh`) that parses the verification gate command from `CLAUDE.md`, runs it, captures the real exit code, and fails the iteration if the observed result diverges from the self-reported `<gate-result>` tag. Update the decision register's "Verification truth" row from `ritual-bounded` to `bounded`.

**Sketch:**

```bash
# .git/hooks/pre-push (installed by scripts/hooks/install.sh)
#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(git rev-parse --show-toplevel)"

# Extract the verification gate command from CLAUDE.md.
# Convention: the gate lives in a fenced code block directly under
# "## Verification Gate" in CLAUDE.md.
GATE_CMD=$(awk '
  /^## Verification Gate/ { in_section = 1; next }
  in_section && /^## / { in_section = 0 }
  in_section && /^```/ { in_fence = !in_fence; next }
  in_section && in_fence { print }
' "$PROJECT_ROOT/CLAUDE.md")

if [ -z "$GATE_CMD" ]; then
  echo "pre-push: no verification gate command found in CLAUDE.md — skipping."
  exit 0
fi

if ! bash -c "$GATE_CMD"; then
  echo "BLOCKED: verification gate failed on pre-push."
  echo "  The agent may have self-reported PASS without running the gate,"
  echo "  or the gate regressed since the last commit."
  exit 1
fi
```

Add the installer block to `scripts/hooks/install.sh`. Document the split in `CLAUDE.md` (and remove the prose caveat at kickoff line 197 once the hook lands — that's an instance of the repo's own "promote, don't repeat" rule).

---

## 2. Testing Pyramid gap — no automated tests for the template's own parser logic

**Law:** Testing Pyramid.

**Where:** `scripts/hooks/install.sh` lines 256–525 (failure-mode register integrity, decision register integrity, CLAUDE.md model-tag validator). Also the tag parsing in `scripts/ralph/ralph.sh` lines 105–116, 205–222, 313–319.

**What's wrong:** The awk parsers in the pre-commit hooks are the mechanism that every other contract in the repo rests on. If they mis-parse a table, the whole register-integrity story is vapor. `CONTRIBUTING.md` line 30 says *"Test the ralph loop end-to-end if you modify any script"* — but end-to-end manual runs don't exercise edge cases like escaped pipes, Unicode in cells, rows that are exactly 5 columns, rows with trailing whitespace before the final pipe, multi-line continuations the hook is supposed to reject, etc. The parsers are complex enough to have real edge cases and simple enough to test cheaply — exactly where the pyramid says to invest.

**Why BLE doesn't excuse this:** The parsers *are* the mechanism. Testing the mechanism is mechanism-for-outcomes one level up. A future model (or human) editing `install.sh` has no automated way to verify the edit didn't break an existing awk case; they'd have to invent test fixtures from scratch each time. That's scaffolding that fights future changes rather than supporting them.

**Recommended fix:** Add a `tests/hooks/` directory with a small `bats` or `shunit2` suite that exercises each parser against known-good and known-bad fixtures. Wire it into `CONTRIBUTING.md` as the first verification step before the end-to-end ralph run.

**Sketch (bats):**

```bash
# tests/hooks/test_register_integrity.bats
#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init --quiet
  cp "$BATS_TEST_DIRNAME/../../scripts/hooks/install.sh" .
  mkdir -p docs
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "fm register: rejects row with bad Status" {
  cat > docs/failure-modes.md <<EOF
| Module | Failure mode | Category | Check | Status |
|--------|-------------|----------|-------|--------|
| a.b    | fails       | input    | t.py  | tested-manually |
EOF
  run bash -c ". ./install.sh && run_fm_integrity_check"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "BLOCKED" ]]
}

@test "fm register: accepts row with covered Status and existing check file" {
  mkdir -p tests
  touch tests/test_a.py
  cat > docs/failure-modes.md <<EOF
| Module | Failure mode | Category | Check           | Status  |
|--------|-------------|----------|-----------------|---------|
| a.b    | fails       | input    | tests/test_a.py | covered |
EOF
  run bash -c ". ./install.sh && run_fm_integrity_check"
  [ "$status" -eq 0 ]
}

@test "decision register: rejects multi-line continuation row" {
  cat > docs/decision-register.md <<EOF
| Decision point | Where | Bounding | Enforcement | Status |
|----------------|-------|----------|-------------|--------|
| Solution selection | impl | check    | hook        | bounded |
| | | continuation of previous row | | |
EOF
  run bash -c ". ./install.sh && run_dec_integrity_check"
  [ "$status" -eq 1 ]
}

# ... etc for each parser branch
```

This will require light refactoring of `install.sh` to expose the parser blocks as callable functions (currently they're inlined inside the generated pre-commit script). Small refactor, large payoff.

---

## 3. Tightenable, not violating — rubric-edit is not mechanically enforced

**Law:** Goodhart's Law (again, in miniature).

**Where:** `project-kickoff-prompt.md` line 105 states the contract: *"The shipped starter alone does not satisfy this contract; an unedited starter means 'Review verdict' cannot legitimately be `bounded`."* No hook in `scripts/hooks/install.sh` enforces this.

**Why this isn't a violation:** The Phase 1 checklist is user-approved — *"Done when all of the following hold and I have approved each."* Human approval is the enforcement mechanism, which is `ritual-bounded` per the repo's own taxonomy (kickoff line 70), and `ritual-bounded` is an acceptable status. So the current design is internally consistent.

**Why it's worth tightening:** Every other Phase 1 contract that *can* be mechanically enforced *is* mechanically enforced (hooks demonstrably reject bad commits; registers must reach disk; baseline rows are required). This is the only Phase 1 checklist item where a one-line grep would promote `ritual-bounded` → `bounded` and reduce Phase-1-approval burden on the user. Pure upside.

**Recommended fix:**

```bash
# Add to the pre-commit hook block in scripts/hooks/install.sh
RUBRIC_FILE="$PROJECT_ROOT/docs/skills/review-rubric.md"
if [ -f "$RUBRIC_FILE" ]; then
  # The shipped starter explicitly identifies itself as a starter.
  # After Phase 1, that disclaimer must be gone (replaced with a project-named header).
  if grep -qF "This file is a starter rubric" "$RUBRIC_FILE"; then
    # Allow during Phase 1 bootstrap (before any bead exists)
    if [ -n "$IN_PROGRESS_BEAD" ]; then
      echo "BLOCKED: docs/skills/review-rubric.md still contains the starter disclaimer."
      echo ""
      echo "  Phase 1 contract: replace the 'starter rubric' disclaimer with a"
      echo "  project-named header and add at least one project-specific clause."
      echo "  Reference: project-kickoff-prompt.md, Phase 1 outcome contract."
      exit 1
    fi
  fi
fi
```

Promote the "Review verdict" row in the decision register from `ritual-bounded` to `bounded` once this hook ships.

---

## 4. Nit — dangling `AGENTS.md` reference in CONTRIBUTING.md

**Where:** `CONTRIBUTING.md` line 52: `rm -rf .beads AGENTS.md .pytest_cache`.

**What's wrong:** `AGENTS.md` appears exactly once in the repo, with no explanation of what produces it. It's almost certainly a Sourcegraph Amp artifact (Amp uses `AGENTS.md` as its equivalent of `CLAUDE.md`), but that's implicit knowledge a new contributor would have to infer. The cleanup command works regardless, so this is cosmetic.

**Recommended fix:** Add a parenthetical:

```markdown
rm -rf .beads AGENTS.md .pytest_cache
# .beads: created by `bd init`
# AGENTS.md: created by Amp on first run (analogous to Claude Code's CLAUDE.md)
# .pytest_cache: created if the test bead's verification gate runs pytest
```

---

## Priority order

1. **Gate-bypass pre-push hook** — highest leverage. Closes the biggest ritual-bounded → bounded gap in the repo.
2. **Parser tests** — protects every other contract. Small effort, durable payoff.
3. **Rubric-edit hook** — pure upside, ~10 lines of shell.
4. **AGENTS.md comment** — 3-line doc edit whenever the file is next touched.

Everything else in the audit was either correctly handled by the repo already or retracted under scrutiny. The codebase is in good shape; these are tightenings, not rescues.
