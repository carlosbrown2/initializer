#!/usr/bin/env bats
# tests/hooks/gate.bats — regression tests for the verification gate command
# declared under "## Verification Gate" in CLAUDE.md.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/hooks/parsers.sh"
  GATE_CMD=$(gate_command_extract "$CLAUDE_MD")
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "gate command is extractable from CLAUDE.md" {
  [ -n "$GATE_CMD" ]
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

@test "install.sh pre-push heredoc sources parsers.sh and calls gate_command_extract" {
  # Single-source the gate extractor. If a future edit re-inlines the awk in
  # the pre-push heredoc, this clause catches it before merge.
  local installer="$PROJECT_ROOT/scripts/hooks/install.sh"
  grep -qF 'source "$PARSERS_LIB"' "$installer"
  grep -qE 'GATE_CMD=\$\(gate_command_extract "\$CLAUDE_MD"\)' "$installer"
}

@test "install.sh does not re-inline the Verification Gate awk extractor" {
  # The anchored-awk pattern `/^## Verification Gate[[:space:]]*$/` is the
  # unique signature of the extractor. It belongs in scripts/hooks/parsers.sh
  # only. If it reappears in install.sh, someone has re-inlined the extractor.
  run grep -E '/\^## Verification Gate' "$PROJECT_ROOT/scripts/hooks/install.sh"
  [ "$status" -ne 0 ]
}

@test "gate.bats (this file) does not re-inline the Verification Gate awk extractor" {
  # Self-check: this test file itself must not contain the extractor awk. It
  # may reference the pattern in comments (the guard strings are string
  # literals in grep args), but never as the awk address that begins the
  # extraction section.
  local self="$BATS_TEST_DIRNAME/gate.bats"
  run grep -E '^[[:space:]]*/\^## Verification Gate' "$self"
  [ "$status" -ne 0 ]
}

@test "gate_command_extract output matches what install.sh's pre-push hook would extract" {
  # End-to-end equivalence: extract the pre-push heredoc body from install.sh
  # (the source of truth for what gets written to .git/hooks/pre-push),
  # truncate it right after GATE_CMD= so sourcing doesn't run the gate, then
  # compare its extracted value to gate_command_extract from parsers.sh.
  # Fails closed if either caller drifts from the shared library.
  local installer="$PROJECT_ROOT/scripts/hooks/install.sh"
  local hook_body="$TMPDIR_TEST/pre-push.sh"
  awk '
    /cat > "\$GIT_HOOKS_DIR\/pre-push" << .HOOK_EOF.$/ { collect=1; next }
    collect && /^HOOK_EOF$/ { collect=0 }
    collect { print }
  ' "$installer" > "$hook_body"
  [ -s "$hook_body" ]

  awk '
    { print }
    /^GATE_CMD=/ { exit }
  ' "$hook_body" > "$hook_body.trunc"

  local hook_output
  hook_output=$(
    set -euo pipefail
    git() {
      if [ "$1" = rev-parse ] && [ "$2" = --show-toplevel ]; then
        printf '%s\n' "$PROJECT_ROOT"
        return 0
      fi
      command git "$@"
    }
    # shellcheck source=/dev/null
    source "$hook_body.trunc"
    printf '%s\n' "$GATE_CMD"
  )
  local lib_output
  lib_output=$(gate_command_extract "$CLAUDE_MD")
  [ -n "$hook_output" ]
  [ "$hook_output" = "$lib_output" ]
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
