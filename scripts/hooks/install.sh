#!/bin/bash
# Install pre-commit hooks for structural constraint enforcement.
# Run this once after cloning a project created from Initializer.
#
# Hooks installed (pre-commit, in execution order inside the hook):
#   1. CLAUDE.md size guard
#   2. Dependency hallucination check (commented out)
#   3. Bead type fail-closed gate (now fail-closed on bd extraction failure too)
#   4. Rubric-edit guard
#   5. Review/research bead write-protection
#   6. Scope enforcement
#   7. Failure-mode register integrity
#   8. Decision register integrity
#   9. Register symbol-refs validator
#  10. Review artifact validator
#  11. CLAUDE.md model-tag validator
#  12. CLAUDE.md pattern-citation validator
#
# Also installed:
#   commit-msg: enforces "<type>: [bead-id] - <title>" format on bead commits
#               (or "<type>: <description>" for non-bead commits).
#   pre-push:   re-runs the verification gate declared under "## Verification Gate"
#               in CLAUDE.md.
#
# Usage: ./scripts/hooks/install.sh

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
GIT_HOOKS_DIR="$PROJECT_ROOT/.git/hooks"

if [ ! -d "$GIT_HOOKS_DIR" ]; then
  echo "Error: .git/hooks not found. Run 'git init' first."
  exit 1
fi

# --- Pre-commit hook ---
cat > "$GIT_HOOKS_DIR/pre-commit" << 'HOOK_EOF'
#!/bin/bash
# Pre-commit hook: structural constraint enforcement
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
CLAUDE_MD_MAX_LINES=200

# Register-integrity parsers live in scripts/hooks/parsers.sh so they can be
# exercised by tests/hooks/parsers.bats outside a live pre-commit context.
PARSERS_LIB="$PROJECT_ROOT/scripts/hooks/parsers.sh"
if [ ! -f "$PARSERS_LIB" ]; then
  echo "BLOCKED: scripts/hooks/parsers.sh not found at $PARSERS_LIB."
  echo "  The pre-commit hook depends on this file for register parsers."
  echo "  Run ./scripts/hooks/install.sh from the project root to (re)install."
  exit 1
fi
# shellcheck source=/dev/null
source "$PARSERS_LIB"

# --- CLAUDE.md size guard ---
if git diff --cached --name-only | grep -q "^CLAUDE.md$"; then
  line_count=$(git show :CLAUDE.md 2>/dev/null | wc -l | tr -d ' ')
  if [ "$line_count" -gt "$CLAUDE_MD_MAX_LINES" ]; then
    echo "BLOCKED: CLAUDE.md has $line_count lines (max $CLAUDE_MD_MAX_LINES)."
    echo ""
    echo "  How to fix:"
    echo "    1. Identify domain-specific content (conventions, pitfalls, examples for a specific area)"
    echo "    2. Move it to docs/skills/<domain>.md (see existing skill files for format)"
    echo "    3. Keep only cross-cutting rules, invariants, and architecture decisions in CLAUDE.md"
    echo "    4. Reference the skill file from CLAUDE.md if needed: 'See docs/skills/<domain>.md'"
    exit 1
  fi
fi

# --- Dependency hallucination check ---
# Uncomment after installing dep-hallucinator:
#
# MANIFEST_FILES=$(git diff --cached --name-only | grep -E '(requirements.*\.txt|package\.json|pyproject\.toml|Cargo\.toml|go\.mod)' || true)
# if [ -n "$MANIFEST_FILES" ]; then
#   if command -v dep-hallucinator &>/dev/null; then
#     dep-hallucinator check $MANIFEST_FILES || {
#       echo "BLOCKED: Dependency hallucination check failed."
#       exit 1
#     }
#   else
#     echo "WARNING: dep-hallucinator not installed. Skipping dependency validation."
#     echo "  Install: pip install dep-hallucinator"
#   fi
# fi

# --- Bead type detection (fail-closed on bd errors too) ---
# When a bead is in progress (per the beads CLI), .current-bead-type MUST exist
# and hold a valid value. Previously this block conditioned on a grep-based
# extraction that silently returned empty on bd format changes, bypassing the
# whole gate chain. bd_bead_in_progress (parsers.sh) uses --json and returns
# non-zero on extraction failure, so a broken bd BLOCKS the commit instead of
# silently letting it through. Phase 1 bootstrap (no bd installed) still passes.
BEAD_TYPE_FILE="$PROJECT_ROOT/.current-bead-type"
BEAD_TYPE=""
if [ -f "$BEAD_TYPE_FILE" ]; then
  BEAD_TYPE=$(tr -d '[:space:]' < "$BEAD_TYPE_FILE")
fi

IN_PROGRESS_BEAD=""
if command -v bd >/dev/null 2>&1; then
  if ! IN_PROGRESS_BEAD=$(bd_bead_in_progress); then
    echo "BLOCKED: unable to determine in-progress bead state from bd."
    echo ""
    echo "  bd_bead_in_progress failed (bd list --status=in_progress errored or"
    echo "  produced non-parseable JSON). This hook is fail-closed: if we can't"
    echo "  verify there is no in-progress bead, we refuse the commit rather than"
    echo "  let the bead-type / scope / write-protection gates silently no-op."
    echo ""
    echo "  How to fix: run 'bd list --status=in_progress --json' manually and"
    echo "  resolve the error (bd version drift, database corruption, missing"
    echo "  bd init, etc.) before committing."
    exit 1
  fi
fi

if [ -n "$IN_PROGRESS_BEAD" ]; then
  case "$BEAD_TYPE" in
    impl|review|pare|compound|research)
      ;;
    "")
      echo "BLOCKED: bead $IN_PROGRESS_BEAD is in progress but .current-bead-type is missing."
      echo ""
      echo "  Write the bead's type to .current-bead-type before committing. One of:"
      echo "    impl     — implementation bead"
      echo "    review   — read-only review bead (artifacts to docs/reviews/ only)"
      echo "    pare     — pare-down bead"
      echo "    compound — compound/learning bead"
      echo "    research — read-only research bead (artifacts to docs/reviews/ only)"
      echo ""
      echo "  The marker is required so scope enforcement and write protection can fire."
      echo "  If the in-progress state is wrong, fix it in beads (bd update / bd close)."
      exit 1
      ;;
    *)
      echo "BLOCKED: .current-bead-type has invalid value '$BEAD_TYPE'."
      echo "  Valid values: impl | review | pare | compound | research"
      exit 1
      ;;
  esac
fi

# --- Rubric-edit guard (Phase 1 completion check) ---
RUBRIC_FILE="$PROJECT_ROOT/docs/skills/review-rubric.md"
if [ -n "$IN_PROGRESS_BEAD" ] && [ -f "$RUBRIC_FILE" ]; then
  if ! reason=$(rubric_edit_check "$RUBRIC_FILE"); then
    echo "BLOCKED: docs/skills/review-rubric.md is still the unedited starter."
    echo ""
    echo "  Reason: $reason"
    echo ""
    echo "  Phase 1 contract (project-kickoff-prompt.md): replace the 'starter rubric'"
    echo "  disclaimer with a project-named header and add at least one project-specific"
    echo "  clause. Without this, 'Review verdict' in docs/decision-register.md cannot"
    echo "  legitimately be claimed bounded — the rubric is not actually project-specific."
    echo ""
    echo "  How to fix:"
    echo "    1. Replace the '# Review Severity Rubric' header with a project-named one"
    echo "       (e.g., '# <Project> Review Severity Rubric')."
    echo "    2. Delete or rephrase the 'This file is a starter rubric' paragraph."
    echo "    3. Add at least one project-specific clause under P1, P2, or P3 that is"
    echo "       not in the starter allowlist (see RUBRIC_STARTER_CLAUSES in"
    echo "       scripts/hooks/parsers.sh)."
    echo ""
    echo "  Phase 1 bootstrap (before any bead is in_progress) is exempt."
    exit 1
  fi
fi

# --- Review/research bead write protection ---
if [ "$BEAD_TYPE" = "review" ] || [ "$BEAD_TYPE" = "research" ]; then
  NON_REVIEW_FILES=$(git diff --cached --name-only | grep -v "^docs/reviews/" || true)
  if [ -n "$NON_REVIEW_FILES" ]; then
    echo "BLOCKED: $BEAD_TYPE beads are read-only — only docs/reviews/ files may be modified."
    echo ""
    echo "  Rejected files:"
    echo "$NON_REVIEW_FILES" | awk '{print "    "$0}'
    echo ""
    echo "  How to fix:"
    echo "    - Write all findings to docs/reviews/<story-id>.md instead of modifying source"
    echo "    - If a fix is needed, note it as a P1 finding — it will be addressed in the pare-down bead"
    echo "    - If the hook itself is wrong, fix the hook (never bypass it)"
    exit 1
  fi
fi

# --- Scope enforcement (bead-level) ---
SCOPE_FILE="$PROJECT_ROOT/.current-bead-scope"

INFRA_PATHS=(
  "docs/failure-modes.md"
  "docs/decision-register.md"
  "docs/reviews/"
  "scripts/ralph/archive.txt"
  "scripts/ralph/patterns.md"
  "scripts/ralph/retry_state.json"
  ".current-bead-type"
  ".current-bead-scope"
)

if [ "$BEAD_TYPE" = "compound" ]; then
  INFRA_PATHS+=("CLAUDE.md" "docs/skills/" "tests/regression/")
fi

is_infra_path() {
  local file="$1"
  for infra in "${INFRA_PATHS[@]}"; do
    case "$file" in
      "$infra"|"$infra"*) return 0 ;;
    esac
  done
  return 1
}

case "$BEAD_TYPE" in
  impl|pare|compound)
    if [ ! -f "$SCOPE_FILE" ]; then
      echo "BLOCKED: $BEAD_TYPE beads require .current-bead-scope to be set."
      echo ""
      echo "  Write the bead's in-scope file paths (one per line) to .current-bead-scope"
      echo "  before committing. Example:"
      echo "    src/auth/"
      echo "    tests/test_auth.py"
      echo ""
      echo "  Always-allowed infrastructure paths (no need to list):"
      for p in "${INFRA_PATHS[@]}"; do echo "    $p"; done
      exit 1
    fi
    ;;
esac

if [ -f "$SCOPE_FILE" ]; then
  ALLOWED_PATHS=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    ALLOWED_PATHS+=("$line")
  done < "$SCOPE_FILE"

  out_of_scope=""
  while IFS= read -r file; do
    [ -z "$file" ] && continue

    if is_infra_path "$file"; then
      continue
    fi

    in_scope=false
    for pattern in "${ALLOWED_PATHS[@]}"; do
      case "$file" in
        "$pattern"|"$pattern"*)
          in_scope=true
          break
          ;;
      esac
    done

    if [ "$in_scope" = false ]; then
      out_of_scope="${out_of_scope}
    ${file}"
    fi
  done <<< "$(git diff --cached --name-only)"

  if [ -n "$out_of_scope" ]; then
    echo "BLOCKED: Files outside the current bead's declared scope:"
    printf '%s\n' "$out_of_scope"
    echo ""
    echo "  Allowed paths (.current-bead-scope):"
    for p in "${ALLOWED_PATHS[@]}"; do echo "    $p"; done
    echo ""
    echo "  Always-allowed infrastructure paths:"
    for p in "${INFRA_PATHS[@]}"; do echo "    $p"; done
    echo ""
    echo "  How to fix: either move the change to a different bead, or add the path"
    echo "  to .current-bead-scope if it legitimately belongs to this bead's scope."
    exit 1
  fi
fi

# --- Failure-mode register integrity ---
FM_REGISTER="$PROJECT_ROOT/docs/failure-modes.md"
if [ -f "$FM_REGISTER" ]; then
  if ! bad_rows=$(fm_status_check "$FM_REGISTER"); then
    echo "BLOCKED: docs/failure-modes.md has rows without an acceptable Status in the last cell."
    echo ""
    echo "  Every data row must end in one of:"
    echo "    covered           — there is a mechanical check for this failure mode"
    echo "    proven-impossible — written argument inline why this can't occur"
    echo "    out-of-scope      — PRD section explicitly excludes this failure mode"
    echo ""
    echo "  Each row must be a single line (multi-line continuation rows are not supported)."
    echo ""
    echo "  Offending rows:"
    echo "$bad_rows" | awk '{print "    "$0}'
    echo ""
    echo "  How to fix: bind each row to a mechanical check, or move the row's coverage"
    echo "  to a follow-up bead and mark it explicitly."
    exit 1
  fi

  STAGED_FILES=$(git diff --cached --name-only)
  if ! missing_refs=$(fm_file_refs_check "$FM_REGISTER" "$PROJECT_ROOT" "$STAGED_FILES"); then
    echo "BLOCKED: docs/failure-modes.md references files that do not exist:"
    printf '%s\n' "$missing_refs"
    echo ""
    echo "  How to fix: create the check file (and its assertions) in this same commit,"
    echo "  or correct the path in the register."
    exit 1
  fi

  if ! missing_syms=$(register_symbol_refs_check "$FM_REGISTER" "$PROJECT_ROOT"); then
    echo "BLOCKED: docs/failure-modes.md cites symbols that are not defined in the named file:"
    printf '%s\n' "$missing_syms"
    echo ""
    echo "  Accepted defining forms (grep-based, not AST):"
    echo "    def <symbol>(           — Python function"
    echo "    async def <symbol>(     — Python async function"
    echo "    class <symbol>(...)     — Python class with bases"
    echo "    class <symbol>:         — Python class without bases"
    echo "    <symbol> = ...          — module-level assignment"
    echo "    <symbol>: <type>        — annotated module-level assignment"
    echo ""
    echo "  How to fix: rename or restore the cited symbol, or update the register row"
    echo "  to cite the new name. The check skips missing files (delegated to"
    echo "  file-refs-check) and gitignored files (no checked-in source)."
    exit 1
  fi
fi

# --- Decision register integrity ---
DEC_REGISTER="$PROJECT_ROOT/docs/decision-register.md"
if [ -f "$DEC_REGISTER" ]; then
  if ! missing=$(dec_required_rows_check "$DEC_REGISTER"); then
    echo "BLOCKED: docs/decision-register.md missing required baseline decision points:"
    printf '%s\n' "$missing"
    echo ""
    echo "  Every project must have rows for these baseline decisions. Add them"
    echo "  with a bounding mechanism and an enforcement strategy."
    exit 1
  fi

  if ! bad_rows=$(dec_row_structure_check "$DEC_REGISTER"); then
    echo "BLOCKED: docs/decision-register.md has malformed rows."
    echo ""
    echo "  Every data row must be a single line with at least 5 columns whose last"
    echo "  cell holds a Status of:"
    echo "    bounded          — hook/gate/test/schema mechanically constrains the agent's choice"
    echo "    ritual-bounded   — bounded by a documented ritual or human step with a re-run cadence"
    echo "    agent-discretion — explicitly unconstrained, with a one-line rationale"
    echo "    escalation-only  — agent must surface via BLOCKED, human decides"
    echo ""
    echo "  Multi-line continuation rows are not supported — keep each row on one line."
    echo ""
    echo "  Offending rows:"
    echo "$bad_rows" | awk '{print "    "$0}'
    exit 1
  fi

  STAGED_FILES="${STAGED_FILES:-$(git diff --cached --name-only)}"
  if ! missing_dec_refs=$(dec_file_refs_check "$DEC_REGISTER" "$PROJECT_ROOT" "$STAGED_FILES"); then
    echo "BLOCKED: docs/decision-register.md references files that do not exist:"
    printf '%s\n' "$missing_dec_refs"
    echo ""
    echo "  Every bounding mechanism that names a file must point to a real file."
    echo "  Either create the file in this same commit, or correct the path in the register."
    exit 1
  fi

  if ! missing_dec_syms=$(register_symbol_refs_check "$DEC_REGISTER" "$PROJECT_ROOT"); then
    echo "BLOCKED: docs/decision-register.md cites symbols that are not defined in the named file:"
    printf '%s\n' "$missing_dec_syms"
    echo ""
    echo "  Accepted defining forms (grep-based, not AST):"
    echo "    def <symbol>(           — Python function"
    echo "    async def <symbol>(     — Python async function"
    echo "    class <symbol>(...)     — Python class with bases"
    echo "    class <symbol>:         — Python class without bases"
    echo "    <symbol> = ...          — module-level assignment"
    echo "    <symbol>: <type>        — annotated module-level assignment"
    echo ""
    echo "  How to fix: rename or restore the cited symbol, or update the register row"
    echo "  to cite the new name. The check skips missing files (delegated to"
    echo "  file-refs-check) and gitignored files (no checked-in source)."
    exit 1
  fi
fi

# --- Review artifact validator ---
# Quote-safe iteration: previous `for f in $REVIEW_FILES; do` word-split on
# IFS, which would corrupt filenames containing spaces. Read NUL-separated
# list via `git diff -z` and iterate with `while IFS= read -r`.
if [ "$BEAD_TYPE" = "review" ]; then
  RUBRIC_PATH="$PROJECT_ROOT/docs/skills/review-rubric.md"
  while IFS= read -r -d '' f; do
    [ -z "$f" ] && continue
    case "$f" in
      docs/reviews/*.md) ;;
      *) continue ;;
    esac
    [ -f "$PROJECT_ROOT/$f" ] || continue

    if ! grep -qF 'docs/skills/review-rubric.md' "$PROJECT_ROOT/$f"; then
      echo "BLOCKED: $f does not cite docs/skills/review-rubric.md."
      echo ""
      echo "  Every review artifact must reference the rubric so the verdict is bounded"
      echo "  by a checked-in standard, not by the model's intuition."
      echo ""
      echo "  How to fix: add a line citing the rubric, e.g.:"
      echo "    > Findings cite clauses from docs/skills/review-rubric.md."
      exit 1
    fi

    if ! grep -qE 'P[123]\.[a-z][a-z-]*' "$PROJECT_ROOT/$f"; then
      echo "BLOCKED: $f does not contain any severity clause citations."
      echo ""
      echo "  Every finding must cite a clause from docs/skills/review-rubric.md."
      echo "  Examples: P1.correctness, P2.weak-test, P3.docstring-drift"
      exit 1
    fi

    if ! invented_clauses=$(review_artifact_clauses_check "$PROJECT_ROOT/$f" "$RUBRIC_PATH"); then
      echo "BLOCKED: $f cites clauses that are not defined in docs/skills/review-rubric.md."
      echo ""
      echo "  Offending clauses:"
      echo "$invented_clauses" | awk '{print "    "$0}'
      echo ""
      echo "  The validator extracts the canonical clause set from bold-marker definitions"
      echo "  ('**P[123].name**') in the rubric. Citing a clause that isn't defined makes"
      echo "  'each finding cites a clause' (decision-register: Review verdict) into a Goodhart"
      echo "  on clause-shape rather than membership."
      echo ""
      echo "  How to fix: either"
      echo "    1. correct the citation to a clause that exists in the rubric, OR"
      echo "    2. add the new clause to docs/skills/review-rubric.md as a"
      echo "       '**P[123].name**' bullet under '## Severity definitions' so it becomes part"
      echo "       of the canonical set (no separate registration step is needed)."
      exit 1
    fi
  done < <(git diff --cached --name-only --diff-filter=AM -z)
fi

# --- CLAUDE.md model-tag validator ---
if git diff --cached --name-only | grep -qx 'CLAUDE.md'; then
  if ! bad_patterns=$(claude_model_tags_check "$PROJECT_ROOT/CLAUDE.md"); then
    echo "BLOCKED: CLAUDE.md ## Discovered Patterns has entries without a model: tag."
    echo ""
    echo "  Every pattern under ## Discovered Patterns must carry a model: tag identifying"
    echo "  its source model so it can be retired or re-validated on model upgrade."
    echo ""
    echo "  Each pattern is a ### heading followed by content. Add a 'model:' line"
    echo "  inside each entry, e.g.:"
    echo "    ### Use anyio for async I/O"
    echo "    model: claude-opus-4-6"
    echo "    why: ..."
    echo ""
    echo "  Offending entries (line: heading):"
    echo "$bad_patterns" | awk '{print "    "$0}'
    exit 1
  fi

  if ! uncited_patterns=$(pattern_citation_check "$PROJECT_ROOT/CLAUDE.md"); then
    echo "BLOCKED: CLAUDE.md ## Discovered Patterns has entries without a binding citation."
    echo ""
    echo "  Every pattern under ## Discovered Patterns must cite a checked-in artifact"
    echo "  so the pattern is bound to something a later reader can verify, not just to"
    echo "  prose. Without this, ## Discovered Patterns has only a count bound (the"
    echo "  200-line CLAUDE.md cap) and bytes can grow while line count stays flat."
    echo ""
    echo "  Accepted citation forms (any one suffices):"
    echo "    <dir>/<path>.<ext>::<symbol>      — symbol-resolvable citation, e.g."
    echo "                                          scripts/hooks/parsers.sh::FOO"
    echo "    tests/...                          — test / fixture path, e.g."
    echo "                                          tests/hooks/parsers.bats"
    echo "    docs/failure-modes.md              — failure-mode register row mention"
    echo "    docs/decision-register.md          — decision-register row mention"
    echo ""
    echo "  Offending entries (line: heading):"
    echo "$uncited_patterns" | awk '{print "    "$0}'
    exit 1
  fi
fi

exit 0
HOOK_EOF

chmod +x "$GIT_HOOKS_DIR/pre-commit"

# --- Commit-msg hook (commit message format validation) ---
# Now actually enforces the [bead-id] - <title> structure advertised by
# prompt.md for bead commits. Non-bead commits (no bracketed id) still
# pass if they have a valid type prefix and a non-empty description.
cat > "$GIT_HOOKS_DIR/commit-msg" << 'HOOK_EOF'
#!/bin/bash
# Commit-msg hook: enforce ralph bead commit message format
set -euo pipefail

MSG=$(head -1 "$1")

# Allow merge commits
if echo "$MSG" | grep -qE "^Merge "; then
  exit 0
fi

# Type prefix check
if ! echo "$MSG" | grep -qE "^(feat|fix|refactor|review|compound|research|docs|chore|test): "; then
  echo "BLOCKED: Commit message must start with a valid type prefix."
  echo ""
  echo "  Format:  <type>: [bead-id] - <title>  (bead commits)"
  echo "       or: <type>: <description>        (non-bead commits)"
  echo "  Allowed: feat | fix | refactor | review | compound | research | docs | chore | test"
  echo "  Got:     $MSG"
  echo ""
  echo "  Examples:"
  echo "    feat:     [story-abc123] - Add user authentication"
  echo "    review:   [story-abc123] - Review user authentication"
  echo "    research: [story-abc123] - Survey existing OAuth implementations"
  echo "    fix:      [story-abc123] - Fix login redirect loop"
  echo "    chore:    update README"
  exit 1
fi

# Strip the "<type>: " prefix so we can inspect what follows.
REMAINDER=$(echo "$MSG" | sed -E 's/^(feat|fix|refactor|review|compound|research|docs|chore|test): //')

# Case 1: bracketed bead-id form. If it starts with "[", require the full shape.
# Bead id regex matches scripts/ralph/lib.sh BEAD_ID_REGEX.
if echo "$REMAINDER" | grep -qE '^\['; then
  if ! echo "$REMAINDER" | grep -qE '^\[[a-z][-a-z0-9]*-[a-z0-9]{2,}\] - .+$'; then
    echo "BLOCKED: Bead commit message does not match '[bead-id] - <title>' format."
    echo ""
    echo "  Got: $MSG"
    echo ""
    echo "  Expected form after the type prefix:"
    echo "    [bead-id] - <title>"
    echo ""
    echo "  where bead-id matches [a-z][-a-z0-9]*-[a-z0-9]{2,} (e.g. agent-template-4mw)."
    echo "  The ' - ' separator between the bracketed id and the title is required."
    exit 1
  fi
else
  # Case 2: non-bead form. Just require a non-empty description.
  if [ -z "$REMAINDER" ]; then
    echo "BLOCKED: Commit message is empty after the type prefix."
    echo "  Got: $MSG"
    exit 1
  fi
fi

exit 0
HOOK_EOF

chmod +x "$GIT_HOOKS_DIR/commit-msg"

# --- Pre-push hook (re-runs the verification gate from CLAUDE.md) ---
cat > "$GIT_HOOKS_DIR/pre-push" << 'HOOK_EOF'
#!/bin/bash
# Pre-push hook: re-run the verification gate declared in CLAUDE.md and block
# the push if it fails. See docs/decision-register.md row "Verification truth".
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"

if [ ! -f "$CLAUDE_MD" ]; then
  echo "pre-push: CLAUDE.md not found at $CLAUDE_MD — skipping gate re-run."
  exit 0
fi

# Single-source the gate extractor so this hook and tests/hooks/gate.bats
# cannot drift. See gate_command_extract in scripts/hooks/parsers.sh.
PARSERS_LIB="$PROJECT_ROOT/scripts/hooks/parsers.sh"
if [ ! -f "$PARSERS_LIB" ]; then
  echo "BLOCKED: scripts/hooks/parsers.sh not found at $PARSERS_LIB."
  echo "  The pre-push hook depends on gate_command_extract from this file."
  echo "  Run ./scripts/hooks/install.sh from the project root to (re)install."
  exit 1
fi
# shellcheck source=/dev/null
source "$PARSERS_LIB"

GATE_CMD=$(gate_command_extract "$CLAUDE_MD")

if [ -z "$GATE_CMD" ]; then
  echo "BLOCKED: no verification gate found under '## Verification Gate' in CLAUDE.md."
  echo "  Declare the gate as a fenced code block directly under that heading."
  echo "  Never bypass with --no-verify."
  exit 1
fi

echo "pre-push: re-running verification gate from CLAUDE.md..."
if bash -c "$GATE_CMD"; then
  OBSERVED="PASS"
else
  OBSERVED="FAIL"
fi

SELF_REPORT=""
SELF_REPORT_FILE="$PROJECT_ROOT/.last-gate-result"
if [ -f "$SELF_REPORT_FILE" ]; then
  SELF_REPORT=$(tr -d '[:space:]' < "$SELF_REPORT_FILE")
fi

if [ "$OBSERVED" = "FAIL" ]; then
  echo ""
  echo "BLOCKED: verification gate failed on pre-push (observed=FAIL)."
  if [ "$SELF_REPORT" = "PASS" ]; then
    echo "  DIVERGENCE: .last-gate-result says PASS but the push-time re-run fails."
    echo "  The iteration-time gate (run by scripts/ralph/ralph.sh via lib.sh run_gate)"
    echo "  passed; something changed between then and now. Likely causes: an uncommitted"
    echo "  edit, tree edits after the bead closed, environment drift, test flakiness,"
    echo "  a file present locally but not committed."
  elif [ -n "$SELF_REPORT" ]; then
    echo "  Iteration-time gate result: $SELF_REPORT"
  fi
  echo "  Fix the failing check (or the gate itself). Never bypass with --no-verify."
  exit 1
fi

if [ "$SELF_REPORT" = "FAIL" ]; then
  echo ""
  echo "BLOCKED: observed=PASS but .last-gate-result says FAIL."
  echo "  The iteration-time gate failed but push-time passed. Investigate the divergence"
  echo "  before pushing (stale .last-gate-result, tree changed between bead close and"
  echo "  push, or the gate command is insensitive to the failure the iteration-time run"
  echo "  saw — add a clause that catches it)."
  exit 1
fi

echo "pre-push: verification gate PASS."
exit 0
HOOK_EOF

chmod +x "$GIT_HOOKS_DIR/pre-push"

echo "Hooks installed successfully."
echo "  - Pre-commit: Bead type fail-closed gate (active — requires .current-bead-type when a bead is in_progress)"
echo "  - Pre-commit: Rubric-edit guard (active — rejects the unedited 'starter rubric' once any bead is in_progress)"
echo "  - Pre-commit: Scope enforcement (active — requires .current-bead-scope for impl/pare/compound beads)"
echo "  - Pre-commit: Failure-mode register integrity (active — fires only if docs/failure-modes.md exists)"
echo "  - Pre-commit: Decision register integrity + bounding-mechanism file refs (active — fires only if docs/decision-register.md exists)"
echo "  - Pre-commit: Register symbol-refs validator (active — rejects <path>::<symbol> citations whose symbol is not defined in the cited file; fires when either register exists)"
echo "  - Pre-commit: Review/research bead write protection (active — fires only if .current-bead-type=review|research)"
echo "  - Pre-commit: Review artifact validator (active — fires only if .current-bead-type=review and review files are staged)"
echo "  - Pre-commit: CLAUDE.md model-tag validator (active — fires only if CLAUDE.md is staged)"
echo "  - Pre-commit: CLAUDE.md pattern-citation validator (active — fires only if CLAUDE.md is staged; rejects ## Discovered Patterns entries with no path::symbol / tests/ / docs/{failure-modes,decision-register}.md citation)"
echo "  - Pre-commit: CLAUDE.md size guard (active)"
echo "  - Pre-commit: Dependency hallucination check (commented out — uncomment after installing dep-hallucinator)"
echo "  - Commit-msg: Format validation (active — [bead-id] - <title> enforced for bead commits)"
echo "  - Pre-push:   Verification gate re-run (active — extracts gate from CLAUDE.md and compares against .last-gate-result if present)"
