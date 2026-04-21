#!/bin/bash
# Install pre-commit hooks for structural constraint enforcement.
# Run this once after cloning a project created from Initializer.
#
# Hooks installed (pre-commit, in execution order inside the hook):
#   1. CLAUDE.md size guard — rejects commits pushing CLAUDE.md beyond the line limit
#      (default 200). Domain knowledge belongs in docs/skills/, not the constitution.
#   2. Dependency hallucination check — validates new packages against registries.
#      Ships COMMENTED OUT; uncomment after installing dep-hallucinator.
#   3. Bead type fail-closed gate — when a bead is in_progress, .current-bead-type
#      must exist and hold one of impl|review|pare|compound|research. Closes the
#      "forget the marker → no enforcement" bypass for the hooks below.
#   4. Rubric-edit guard — when a bead is in_progress, docs/skills/review-rubric.md
#      must not still contain the "starter rubric" disclaimer. Phase 1 bootstrap
#      (no in-progress bead) is exempt. Bounds the "Review verdict" decision point.
#   5. Review/research bead write-protection — when .current-bead-type is review or
#      research, only files under docs/reviews/ may change.
#   6. Scope enforcement — rejects commits touching files outside the current bead's
#      declared scope (.current-bead-scope). Always-allowed infrastructure paths are
#      exempt. impl/pare/compound beads MUST have a scope file or the hook blocks.
#   7. Failure-mode register integrity — every row in docs/failure-modes.md must have an
#      acceptable Status (covered | proven-impossible | out-of-scope), and every check
#      file it references must exist on disk.
#   8. Decision register integrity — docs/decision-register.md must contain the baseline
#      decision points (Solution selection, Acceptance interpretation, Sampling variance,
#      Verification truth, Scope creep), every row must have ≥5 columns and an acceptable
#      Status (bounded | ritual-bounded | agent-discretion | escalation-only), and every
#      bounding-mechanism file path it references must exist on disk.
#   9. Review artifact validator — when .current-bead-type=review, files staged in
#      docs/reviews/ must cite docs/skills/review-rubric.md, contain at least one
#      severity clause citation (P1.foo, P2.foo, P3.foo), AND every cited clause
#      must exist as a `**P[123].name**` definition in the rubric (membership check
#      via review_artifact_clauses_check in scripts/hooks/parsers.sh).
#  10. CLAUDE.md model-tag validator — every entry under ## Discovered Patterns in
#      CLAUDE.md must carry a `model:` tag identifying its source model.
#
# Also installed:
#   commit-msg: enforces "<type>: ..." prefix on every commit message
#               (feat|fix|refactor|review|compound|research|docs|chore|test).
#   pre-push:   re-runs the verification gate declared under "## Verification Gate"
#               in CLAUDE.md. Blocks the push if the real gate fails, even when the
#               agent self-reported PASS. Closes the gate-bypass hole that ralph.sh
#               alone cannot cover (it only checks the <gate-result> tag is present).
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
CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"
CLAUDE_MD_MAX_LINES=200

# Register-integrity parsers live in scripts/hooks/parsers.sh so they can be
# exercised by tests/hooks/parsers.bats outside a live pre-commit context.
# Drift between the generated hook and the parsers is prevented by sourcing.
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
# Uncomment the lines below after installing dep-hallucinator:
#   pip install dep-hallucinator   (Python)
#   npm install -g dep-hallucinator (Node)
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

# --- Bead type detection (fail-closed) ---
# When a bead is in progress (per the beads CLI), .current-bead-type MUST exist and
# hold a valid value. This closes the "forget to write the marker → no enforcement"
# bypass that would otherwise let scope enforcement, write protection, and the
# review-artifact validator silently no-op. During Phase 1 (before any beads exist)
# bd returns no in-progress bead and the gate is a no-op, so bootstrap commits work.
BEAD_TYPE_FILE="$PROJECT_ROOT/.current-bead-type"
BEAD_TYPE=""
if [ -f "$BEAD_TYPE_FILE" ]; then
  BEAD_TYPE=$(cat "$BEAD_TYPE_FILE" | tr -d '[:space:]')
fi

IN_PROGRESS_BEAD=""
if command -v bd >/dev/null 2>&1; then
  IN_PROGRESS_BEAD=$(bd list --status=in_progress 2>/dev/null | grep -o '[a-z_]*-[a-z0-9]*-[a-z0-9]*' | head -1) || true
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
# The shipped docs/skills/review-rubric.md carries a "starter rubric" disclaimer,
# a generic header, and a fixed set of starter clauses. Phase 1 contract
# (project-kickoff-prompt.md): the disclaimer must be replaced, the header must
# be renamed, and at least one project-specific clause must be added. Without
# this, "Review verdict" in the decision register cannot legitimately be claimed
# `bounded` — the rubric is not actually project-specific. The check itself
# lives in scripts/hooks/parsers.sh as rubric_edit_check so the bats suite
# under tests/hooks/ exercises it directly. Phase 1 bootstrap (no in-progress
# bead) is exempt so the very first commits can land.
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
# Review and research beads are read-only analysis: only docs/reviews/ may be modified.
if [ "$BEAD_TYPE" = "review" ] || [ "$BEAD_TYPE" = "research" ]; then
  NON_REVIEW_FILES=$(git diff --cached --name-only | grep -v "^docs/reviews/" || true)
  if [ -n "$NON_REVIEW_FILES" ]; then
    echo "BLOCKED: $BEAD_TYPE beads are read-only — only docs/reviews/ files may be modified."
    echo ""
    echo "  Rejected files:"
    echo "$NON_REVIEW_FILES" | sed 's/^/    /'
    echo ""
    echo "  How to fix:"
    echo "    - Write all findings to docs/reviews/<story-id>.md instead of modifying source"
    echo "    - If a fix is needed, note it as a P1 finding — it will be addressed in the pare-down bead"
    echo "    - If the hook itself is wrong, fix the hook (never bypass it)"
    exit 1
  fi
fi

# --- Scope enforcement (bead-level) ---
# Each bead declares its in-scope files/directories in .current-bead-scope (one path
# per line). impl, pare, and compound beads MUST have this file present, or the hook
# blocks. Always-allowed infrastructure paths (the registers, the archive, the patterns
# file, the bead-marker files) are exempt regardless of declared scope.
SCOPE_FILE="$PROJECT_ROOT/.current-bead-scope"

# Always-permitted infrastructure paths (modifiable by any bead type)
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

# Compound beads also need to write CLAUDE.md, docs/skills/, and tests/regression/
# (regression tests for newly-discovered bug classes are part of the compound DoD).
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

# impl/pare/compound beads must have a scope file
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
    # Skip lines that look like comments
    case "$line" in \#*) continue ;; esac
    ALLOWED_PATHS+=("$line")
  done < "$SCOPE_FILE"

  out_of_scope=""
  while IFS= read -r file; do
    [ -z "$file" ] && continue

    # Always allow infrastructure paths
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

# --- Failure-mode register integrity (parsers in scripts/hooks/parsers.sh) ---
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
    echo "$bad_rows" | sed 's/^/    /'
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
fi

# --- Decision register integrity (parsers in scripts/hooks/parsers.sh) ---
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
    echo "$bad_rows" | sed 's/^/    /'
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
fi

# --- Review artifact validator ---
# When .current-bead-type=review, files staged in docs/reviews/ must:
#   1. Cite docs/skills/review-rubric.md (the bounding mechanism for "review verdict")
#   2. Contain at least one severity clause citation (P1.foo, P2.foo, P3.foo)
#   3. Every cited clause must exist as a definition in docs/skills/review-rubric.md
#      (closes the shape-vs-membership Goodhart: previously any well-formed token
#      passed regardless of whether the rubric defined it).
# Research artifacts are not subject to this — they don't classify findings by severity.
if [ "$BEAD_TYPE" = "review" ]; then
  REVIEW_FILES=$(git diff --cached --name-only --diff-filter=AM | grep '^docs/reviews/.*\.md$' || true)
  RUBRIC_PATH="$PROJECT_ROOT/docs/skills/review-rubric.md"
  for f in $REVIEW_FILES; do
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
      echo "$invented_clauses" | sed 's/^/    /'
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
  done
fi

# --- CLAUDE.md model-tag validator (parser in scripts/hooks/parsers.sh) ---
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
    echo "$bad_patterns" | sed 's/^/    /'
    exit 1
  fi
fi

exit 0
HOOK_EOF

chmod +x "$GIT_HOOKS_DIR/pre-commit"

# --- Commit-msg hook (commit message format validation) ---
cat > "$GIT_HOOKS_DIR/commit-msg" << 'HOOK_EOF'
#!/bin/bash
# Commit-msg hook: enforce ralph bead commit message format
set -euo pipefail

MSG=$(cat "$1")

# Allow merge commits
if echo "$MSG" | head -1 | grep -qE "^Merge "; then
  exit 0
fi

# Allowed prefixes: feat, fix, refactor, review, compound, research, docs, chore, test
# Format: <type>: [<bead-id>] - <title>
#   or:   <type>: <description>  (for non-bead commits)
if ! echo "$MSG" | head -1 | grep -qE "^(feat|fix|refactor|review|compound|research|docs|chore|test): "; then
  echo "BLOCKED: Commit message must start with a valid type prefix."
  echo ""
  echo "  Format:  <type>: [Story ID] - <title>"
  echo "  Allowed: feat | fix | refactor | review | compound | research | docs | chore | test"
  echo "  Got:     $(echo "$MSG" | head -1)"
  echo ""
  echo "  Examples:"
  echo "    feat:     [story-abc123] - Add user authentication"
  echo "    review:   [story-abc123] - Review user authentication"
  echo "    research: [story-abc123] - Survey existing OAuth implementations"
  echo "    fix:      [story-abc123] - Fix login redirect loop"
  exit 1
fi

exit 0
HOOK_EOF

chmod +x "$GIT_HOOKS_DIR/commit-msg"

# --- Pre-push hook (re-runs the verification gate from CLAUDE.md) ---
# Closes the gate-bypass hole: ralph.sh only verifies the <gate-result> tag is
# present, not that the gate actually ran. The pre-push hook extracts the gate
# command from CLAUDE.md and runs it for real, so the observed exit code is the
# source of truth at push time. If ralph.sh has written .last-gate-result from
# the agent's self-report, a divergence (self-reported PASS, observed FAIL) is
# called out explicitly in the block message.
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

# Convention: the gate is the first fenced code block directly under the
# "## Verification Gate" heading in CLAUDE.md.
GATE_CMD=$(awk '
  /^## Verification Gate[[:space:]]*$/ { in_section = 1; next }
  in_section && /^## / { in_section = 0 }
  in_section && /^```/ { in_fence = !in_fence; next }
  in_section && in_fence { print }
' "$CLAUDE_MD")

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

# Read the agent's self-reported gate result if ralph.sh persisted one.
# Absent file → no divergence claim to check; the real exit code is authoritative.
SELF_REPORT=""
SELF_REPORT_FILE="$PROJECT_ROOT/.last-gate-result"
if [ -f "$SELF_REPORT_FILE" ]; then
  SELF_REPORT=$(tr -d '[:space:]' < "$SELF_REPORT_FILE")
fi

if [ "$OBSERVED" = "FAIL" ]; then
  echo ""
  echo "BLOCKED: verification gate failed on pre-push (observed=FAIL)."
  if [ "$SELF_REPORT" = "PASS" ]; then
    echo "  DIVERGENCE: agent self-reported PASS but the real gate fails."
    echo "  This is the exact bypass the pre-push hook exists to catch."
  elif [ -n "$SELF_REPORT" ]; then
    echo "  Agent self-reported: $SELF_REPORT"
  fi
  echo "  Fix the failing check (or the gate itself). Never bypass with --no-verify."
  exit 1
fi

if [ "$SELF_REPORT" = "FAIL" ]; then
  echo ""
  echo "BLOCKED: observed=PASS but agent self-reported FAIL."
  echo "  Investigate the divergence before pushing (stale state file, environment drift,"
  echo "  or the gate command is insensitive to the failure the agent saw)."
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
echo "  - Pre-commit: Review/research bead write protection (active — fires only if .current-bead-type=review|research)"
echo "  - Pre-commit: Review artifact validator (active — fires only if .current-bead-type=review and review files are staged)"
echo "  - Pre-commit: CLAUDE.md model-tag validator (active — fires only if CLAUDE.md is staged)"
echo "  - Pre-commit: CLAUDE.md size guard (active)"
echo "  - Pre-commit: Dependency hallucination check (commented out — uncomment after installing dep-hallucinator)"
echo "  - Commit-msg: Format validation (active — feat|fix|refactor|review|compound|research|docs|chore|test)"
echo "  - Pre-push:   Verification gate re-run (active — extracts gate from CLAUDE.md and compares against .last-gate-result if present)"
