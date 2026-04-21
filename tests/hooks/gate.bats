#!/usr/bin/env bats
# tests/hooks/gate.bats — regression tests for the verification gate command
# declared under "## Verification Gate" in CLAUDE.md.
#
# History: agent-template-8gi caught a structural no-op — the gate ended in
# `|| true`, which (because `||` binds to the whole `&&` chain) made every
# in-chain failure silently exit 0. The pre-push hook re-runs whatever the
# gate is, so a no-op gate makes the hook a no-op too. These tests fail-close
# any future re-introduction of that class of bug.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"
  GATE_CMD=$(awk '
    /^## Verification Gate[[:space:]]*$/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^```/ { in_fence = !in_fence; next }
    in_section && in_fence { print }
  ' "$CLAUDE_MD")
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "gate command is extractable from CLAUDE.md" {
  [ -n "$GATE_CMD" ]
}

@test "gate command does not end with '|| true' (would mask all failures)" {
  # Trim trailing whitespace before the check.
  trimmed=$(echo "$GATE_CMD" | sed -e 's/[[:space:]]*$//')
  [[ "$trimmed" != *"|| true" ]]
}

@test "gate command does not contain markdown files (bash -n on .md is meaningless)" {
  [[ "$GATE_CMD" != *".md"* ]]
}

@test "gate command includes bats tests/hooks/ clause" {
  # Structural: the gate must run the bats suite so parser/gate regressions
  # are mechanical rather than discovered via loop failure. Asserting presence
  # by string match prevents accidental removal of the clause.
  [[ "$GATE_CMD" == *"bats tests/hooks/"* ]]
}

@test "gate passes against the current repo (sanity)" {
  # The gate now invokes 'bats tests/hooks/', which re-invokes this very file.
  # Guard recursion with an env-var sentinel: the outer invocation sets the
  # flag and calls the gate; the inner bats run sees the flag and skips this
  # test, so the outer run still exercises every other clause against the
  # real repo.
  if [ "${_BATS_GATE_REENTRY:-0}" = "1" ]; then
    skip "nested bats invocation from the gate — skipping to avoid recursion"
  fi
  cd "$PROJECT_ROOT"
  export _BATS_GATE_REENTRY=1
  run bash -c "$GATE_CMD"
  [ "$status" -eq 0 ]
}

@test "gate fails when scripts/ralph/ralph.sh has a syntax error" {
  # Stage a corrupt copy of the repo and rewrite the gate to point at it.
  # If the gate is structurally sound, breaking ANY single clause must propagate
  # a non-zero exit to the chain.
  cp -R "$PROJECT_ROOT/scripts" "$TMPDIR_TEST/scripts"
  echo 'foo(' > "$TMPDIR_TEST/scripts/ralph/ralph.sh"

  # Re-point each `scripts/...` path in the gate command to the broken tree.
  broken_gate=$(echo "$GATE_CMD" | sed "s|scripts/|$TMPDIR_TEST/scripts/|g")

  run bash -c "$broken_gate"
  [ "$status" -ne 0 ]
}

@test "gate fails when scripts/hooks/parsers.sh has a syntax error" {
  # parsers.sh is sourced by the generated pre-commit hook. A syntax error
  # there silently breaks every register-integrity check; the gate must catch
  # it. This test also fail-closes a future accidental drop of the parsers.sh
  # clause from the chain — if the clause is missing, corrupting parsers.sh
  # would not produce a non-zero exit and this test would fail.
  cp -R "$PROJECT_ROOT/scripts" "$TMPDIR_TEST/scripts"
  echo 'foo(' > "$TMPDIR_TEST/scripts/hooks/parsers.sh"

  broken_gate=$(echo "$GATE_CMD" | sed "s|scripts/|$TMPDIR_TEST/scripts/|g")

  run bash -c "$broken_gate"
  [ "$status" -ne 0 ]
}
