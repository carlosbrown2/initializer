#!/bin/bash
# Install pre-commit hooks for structural constraint enforcement.
# Run this once after cloning a project created from Initializer.
#
# Hooks installed:
#   1. Scope enforcement — rejects commits touching files outside the current bead's
#      declared scope (.current-bead-scope). Always-allowed infrastructure paths are
#      exempt. impl/pare/compound beads MUST have a scope file or the hook blocks.
#   2. CLAUDE.md size guard — rejects commits pushing CLAUDE.md beyond the line limit
#   3. Dependency hallucination check — validates new packages against registries
#   4. Failure-mode register integrity — every row in docs/failure-modes.md must have an
#      acceptable Status (covered | proven-impossible | out-of-scope), and every check
#      file it references must exist
#   5. Decision register integrity — docs/decision-register.md must contain the baseline
#      decision points (Solution selection, Acceptance interpretation, Sampling variance,
#      Verification truth, Scope creep), every row must have ≥5 columns and an acceptable
#      Status (bounded | agent-discretion | escalation-only), and every bounding-mechanism
#      file path it references must exist on disk
#   6. Review artifact validator — when .current-bead-type=review, files staged in
#      docs/reviews/ must cite docs/skills/review-rubric.md AND contain at least one
#      severity clause citation (P1.foo, P2.foo, P3.foo)
#   7. CLAUDE.md model-tag validator — every entry under ## Discovered Patterns in
#      CLAUDE.md must carry a `model:` tag identifying its source model
#   8. Review/research bead write-protection — when .current-bead-type is review or
#      research, only files under docs/reviews/ may change
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
  "progress.txt"
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

# --- Failure-mode register integrity ---
# Every data row in docs/failure-modes.md must end with an acceptable Status
# (covered | proven-impossible | out-of-scope) in its last cell. Every check
# file it references must exist on disk (or be staged for addition).
#
# Note on table format: each row must be on a single line. Multi-line visual
# continuation rows ("| | | continuation text | | |") are flagged because
# their last cell is empty and they have no Status.
FM_REGISTER="$PROJECT_ROOT/docs/failure-modes.md"
if [ -f "$FM_REGISTER" ]; then
  bad_rows=$(awk '
    /^\|/ {
      line = $0
      # Skip separator rows: contain only |, -, :, space
      stripped = line
      gsub(/[|:\- \t]/, "", stripped)
      if (stripped == "") next
      # Skip header rows (contain the column-name "Failure mode" or "Status")
      if (line ~ /Failure mode/ || line ~ /Status[ \t]*\|/) next

      # Parse the last real cell. A markdown table row |c1|c2|...|cN| splits as
      # ["", "c1", "c2", ..., "cN", ""], so the last real cell is at index n-1.
      n = split(line, cells, "|")
      last_cell = cells[n-1]
      sub(/^[ \t]+/, "", last_cell)
      sub(/[ \t]+$/, "", last_cell)
      if (last_cell != "covered" && last_cell != "proven-impossible" && last_cell != "out-of-scope") {
        print NR ": " line
      }
    }
  ' "$FM_REGISTER")
  if [ -n "$bad_rows" ]; then
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

  # Every test/proof file referenced in the register must exist on disk.
  # Extract path-like tokens under common project subdirectories.
  missing_refs=""
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    # Strip any ::test_name suffix (pytest-style references)
    file_part="${ref%%::*}"
    if [ ! -f "$PROJECT_ROOT/$file_part" ]; then
      # Check if it's staged for addition
      if ! git diff --cached --name-only | grep -qx "$file_part"; then
        missing_refs="${missing_refs}
    ${ref}"
      fi
    fi
  done < <(grep -oE '(tests?|proofs|src|spec|docs|tasks|scripts|lib|pkg)/[a-zA-Z0-9_/.-]+\.[a-zA-Z0-9]+(::[a-zA-Z0-9_]+)?' "$FM_REGISTER" | sort -u)

  if [ -n "$missing_refs" ]; then
    echo "BLOCKED: docs/failure-modes.md references files that do not exist:"
    printf '%s\n' "$missing_refs"
    echo ""
    echo "  How to fix: create the check file (and its assertions) in this same commit,"
    echo "  or correct the path in the register."
    exit 1
  fi
fi

# --- Decision register integrity ---
# docs/decision-register.md enumerates every decision point where agent variance
# can enter the project, paired with the structural mechanism that bounds it.
# This hook validates the register's structure: required baseline rows present,
# every row is single-line with >= 5 columns, every row's last cell holds an
# acceptable Status. Bounding-mechanism file references must exist on disk.
DEC_REGISTER="$PROJECT_ROOT/docs/decision-register.md"
if [ -f "$DEC_REGISTER" ]; then
  # Required baseline decision points — every project must have these rows.
  REQUIRED_DECISIONS=(
    "Solution selection"
    "Acceptance interpretation"
    "Sampling variance"
    "Verification truth"
    "Scope creep"
  )

  missing=""
  for d in "${REQUIRED_DECISIONS[@]}"; do
    if ! grep -qF "$d" "$DEC_REGISTER"; then
      missing="${missing}
    ${d}"
    fi
  done

  if [ -n "$missing" ]; then
    echo "BLOCKED: docs/decision-register.md missing required baseline decision points:"
    printf '%s\n' "$missing"
    echo ""
    echo "  Every project must have rows for these baseline decisions. Add them"
    echo "  with a bounding mechanism and an enforcement strategy."
    exit 1
  fi

  # Validate row structure: every data row must have >= 5 cells (>= 6 pipes,
  # ignoring escaped \| inside cells) AND its last cell must hold a valid Status.
  # Multi-line continuation rows are not supported — each row must be a single line.
  bad_rows=$(awk '
    /^\|/ {
      line = $0
      stripped = line
      gsub(/[|:\- \t]/, "", stripped)
      if (stripped == "") next  # separator row
      if (line ~ /Decision point/) next  # header row

      # Count real (unescaped) pipes by stripping \| first
      count_line = line
      gsub(/\\\|/, "", count_line)
      n_pipes = gsub(/\|/, "|", count_line)
      if (n_pipes < 6) {
        print NR ": (too few columns) " $0
        next
      }

      # Parse the last real cell as the Status column
      n = split(line, cells, "|")
      last_cell = cells[n-1]
      sub(/^[ \t]+/, "", last_cell)
      sub(/[ \t]+$/, "", last_cell)
      if (last_cell != "bounded" && last_cell != "ritual-bounded" && last_cell != "agent-discretion" && last_cell != "escalation-only") {
        print NR ": (bad status) " $0
      }
    }
  ' "$DEC_REGISTER")

  if [ -n "$bad_rows" ]; then
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

  # Bounding-mechanism file references must exist on disk.
  # Extract path-like tokens from the register and check each one.
  missing_dec_refs=""
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    if [ ! -f "$PROJECT_ROOT/$ref" ]; then
      # Allow the reference if the file is staged for addition in this commit
      if ! git diff --cached --name-only | grep -qx "$ref"; then
        missing_dec_refs="${missing_dec_refs}
    ${ref}"
      fi
    fi
  done < <(grep -oE '(tests?|proofs|src|spec|docs|tasks|scripts|lib|pkg)/[a-zA-Z0-9_/.-]+\.[a-zA-Z0-9]+' "$DEC_REGISTER" | sort -u)

  if [ -n "$missing_dec_refs" ]; then
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
# Research artifacts are not subject to this — they don't classify findings by severity.
if [ "$BEAD_TYPE" = "review" ]; then
  REVIEW_FILES=$(git diff --cached --name-only --diff-filter=AM | grep '^docs/reviews/.*\.md$' || true)
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
  done
fi

# --- CLAUDE.md model-tag validator ---
# Every entry under ## Discovered Patterns in CLAUDE.md must contain a `model:` tag
# so it can be retired or re-validated on model upgrade. Pattern entries MUST be
# delimited by `### ` headings within the section — that's the contract; bullet-list
# or bold-only patterns are not detected and should not be used.
if git diff --cached --name-only | grep -qx 'CLAUDE.md'; then
  bad_patterns=$(awk '
    BEGIN { in_section = 0; current_entry = ""; current_line = 0; has_model = 0 }
    /^## Discovered Patterns/ {
      in_section = 1
      current_entry = ""
      has_model = 0
      next
    }
    in_section && /^## / {
      if (current_entry != "" && !has_model) {
        print current_line ": " current_entry
      }
      in_section = 0
      next
    }
    in_section && /^### / {
      if (current_entry != "" && !has_model) {
        print current_line ": " current_entry
      }
      current_entry = $0
      current_line = NR
      has_model = 0
      next
    }
    # Anchored: a real tag is "model:" at the start of a line (with optional
    # leading whitespace), followed by whitespace. Prose mentions of "the model"
    # do not match.
    in_section && /^[[:space:]]*model:[[:space:]]/ { has_model = 1 }
    END {
      if (in_section && current_entry != "" && !has_model) {
        print current_line ": " current_entry
      }
    }
  ' "$PROJECT_ROOT/CLAUDE.md")

  if [ -n "$bad_patterns" ]; then
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

echo "Hooks installed successfully."
echo "  - Pre-commit: Bead type fail-closed gate (active — requires .current-bead-type when a bead is in_progress)"
echo "  - Pre-commit: Scope enforcement (active — requires .current-bead-scope for impl/pare/compound beads)"
echo "  - Pre-commit: Failure-mode register integrity (active — fires only if docs/failure-modes.md exists)"
echo "  - Pre-commit: Decision register integrity + bounding-mechanism file refs (active — fires only if docs/decision-register.md exists)"
echo "  - Pre-commit: Review/research bead write protection (active — fires only if .current-bead-type=review|research)"
echo "  - Pre-commit: Review artifact validator (active — fires only if .current-bead-type=review and review files are staged)"
echo "  - Pre-commit: CLAUDE.md model-tag validator (active — fires only if CLAUDE.md is staged)"
echo "  - Pre-commit: CLAUDE.md size guard (active)"
echo "  - Pre-commit: Dependency hallucination check (commented out — uncomment after installing dep-hallucinator)"
echo "  - Commit-msg: Format validation (active — feat|fix|refactor|review|compound|research|docs|chore|test)"
