#!/usr/bin/env bats
# End-to-end tests for the generated pre-commit hook.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMPDIR_TEST="$(mktemp -d)"
  TEST_REPO="$TMPDIR_TEST/repo"
  mkdir -p "$TEST_REPO/scripts/hooks" "$TMPDIR_TEST/bin"

  cp "$PROJECT_ROOT/scripts/hooks/install.sh" "$TEST_REPO/scripts/hooks/install.sh"
  cp "$PROJECT_ROOT/scripts/hooks/parsers.sh" "$TEST_REPO/scripts/hooks/parsers.sh"

  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.email test@example.com
  git -C "$TEST_REPO" config user.name "Test User"

  cat > "$TMPDIR_TEST/bin/bd" <<'EOF'
#!/bin/bash
if [ "$1" = "--no-daemon" ] && [ "$2" = "list" ] && [ "$3" = "--status=in_progress" ] && [ "$4" = "--json" ]; then
  printf '[{"id":"agent-template-3ne"}]'
  exit 0
fi
echo "unexpected bd invocation: $*" >&2
exit 1
EOF
  chmod +x "$TMPDIR_TEST/bin/bd"

  PATH="$TMPDIR_TEST/bin:$PATH" bash "$TEST_REPO/scripts/hooks/install.sh" >/dev/null
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

run_pre_commit() {
  ( cd "$TEST_REPO" && PATH="$TMPDIR_TEST/bin:$PATH" .git/hooks/pre-commit )
}

@test "pre-commit rejects source edits for review beads" {
  printf 'review\n' > "$TEST_REPO/.current-bead-type"
  mkdir -p "$TEST_REPO/src"
  printf '%s\n' '#!/bin/bash' 'echo source-change' > "$TEST_REPO/src/app.sh"
  git -C "$TEST_REPO" add src/app.sh

  run run_pre_commit
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKED: review beads are read-only"* ]]
  [[ "$output" == *"src/app.sh"* ]]
}

@test "pre-commit rejects source edits for research beads" {
  printf 'research\n' > "$TEST_REPO/.current-bead-type"
  mkdir -p "$TEST_REPO/src"
  printf '%s\n' '#!/bin/bash' 'echo source-change' > "$TEST_REPO/src/app.sh"
  git -C "$TEST_REPO" add src/app.sh

  run run_pre_commit
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKED: research beads are read-only"* ]]
  [[ "$output" == *"src/app.sh"* ]]
}

@test "pre-commit allows the current review bead artifact" {
  printf 'review\n' > "$TEST_REPO/.current-bead-type"
  mkdir -p "$TEST_REPO/docs/reviews"
  printf '%s\n' '# Review' > "$TEST_REPO/docs/reviews/agent-template-3ne.md"
  git -C "$TEST_REPO" add docs/reviews/agent-template-3ne.md

  run run_pre_commit
  [ "$status" -eq 0 ]
}

@test "pre-commit allows the current research bead artifact" {
  printf 'research\n' > "$TEST_REPO/.current-bead-type"
  mkdir -p "$TEST_REPO/docs/reviews"
  printf '%s\n' '# Research' > "$TEST_REPO/docs/reviews/agent-template-3ne.md"
  git -C "$TEST_REPO" add docs/reviews/agent-template-3ne.md

  run run_pre_commit
  [ "$status" -eq 0 ]
}

@test "pre-commit allows infrastructure edits for review beads" {
  printf 'review\n' > "$TEST_REPO/.current-bead-type"
  mkdir -p "$TEST_REPO/docs" "$TEST_REPO/scripts/ralph"
  printf '%s\n' '# Failure Modes' > "$TEST_REPO/docs/failure-modes.md"
  printf '%s\n' 'progress' > "$TEST_REPO/scripts/ralph/archive.txt"
  git -C "$TEST_REPO" add docs/failure-modes.md scripts/ralph/archive.txt

  run run_pre_commit
  [ "$status" -eq 0 ]
}

@test "pre-commit rejects a different review artifact for review beads" {
  printf 'review\n' > "$TEST_REPO/.current-bead-type"
  mkdir -p "$TEST_REPO/docs/reviews"
  printf '%s\n' '# Review' > "$TEST_REPO/docs/reviews/agent-template-other.md"
  git -C "$TEST_REPO" add docs/reviews/agent-template-other.md

  run run_pre_commit
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/reviews/agent-template-other.md"* ]]
  [[ "$output" == *"docs/reviews/agent-template-3ne.md"* ]]
}
