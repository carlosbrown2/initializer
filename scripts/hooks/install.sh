#!/bin/bash
# Install pre-commit hooks for structural constraint enforcement.
# Run this once after cloning a project created from Initializer.
#
# Hooks installed:
#   1. Scope enforcement — rejects commits touching files outside the current bead's scope
#   2. CLAUDE.md size guard — rejects commits pushing CLAUDE.md beyond the line limit
#   3. Dependency hallucination check — validates new packages against registries
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

# --- Review bead write protection ---
# If the current bead type is "review", only allow changes to docs/reviews/
BEAD_TYPE_FILE="$PROJECT_ROOT/.current-bead-type"
if [ -f "$BEAD_TYPE_FILE" ]; then
  BEAD_TYPE=$(cat "$BEAD_TYPE_FILE" | tr -d '[:space:]')
  if [ "$BEAD_TYPE" = "review" ]; then
    NON_REVIEW_FILES=$(git diff --cached --name-only | grep -v "^docs/reviews/" || true)
    if [ -n "$NON_REVIEW_FILES" ]; then
      echo "BLOCKED: Review beads are read-only — only docs/reviews/ files may be modified."
      echo ""
      echo "  Rejected files:"
      echo "$NON_REVIEW_FILES" | sed 's/^/    /'
      echo ""
      echo "  How to fix:"
      echo "    - Write all findings to docs/reviews/<story-id>.md instead of modifying source"
      echo "    - If a fix is needed, note it as a P1 finding — it will be addressed in the pare-down bead"
      echo "    - To override (emergency only): rm .current-bead-type"
      exit 1
    fi
  fi
fi

# --- Scope enforcement (bead-level) ---
# This is enforced by convention. The bead description declares in-scope
# files/directories. To enable hard enforcement, uncomment and configure:
#
# SCOPE_FILE="$PROJECT_ROOT/.current-bead-scope"
# if [ -f "$SCOPE_FILE" ]; then
#   ALLOWED_PATHS=$(cat "$SCOPE_FILE")
#   CHANGED_FILES=$(git diff --cached --name-only)
#   for file in $CHANGED_FILES; do
#     in_scope=false
#     for pattern in $ALLOWED_PATHS; do
#       if [[ "$file" == $pattern* ]]; then
#         in_scope=true
#         break
#       fi
#     done
#     if [ "$in_scope" = false ]; then
#       echo "BLOCKED: $file is outside the current bead's declared scope."
#       echo "  Allowed paths: $ALLOWED_PATHS"
#       exit 1
#     fi
#   done
# fi

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

# Allowed prefixes: feat, review, refactor, docs, fix, chore, test
# Format: <type>: [<bead-id>] - <title>
#   or:   <type>: <description>  (for non-bead commits)
if ! echo "$MSG" | head -1 | grep -qE "^(feat|review|refactor|docs|fix|chore|test): "; then
  echo "BLOCKED: Commit message must start with a valid type prefix."
  echo ""
  echo "  Format:  <type>: [Story ID] - <title>"
  echo "  Allowed: feat | review | refactor | docs | fix | chore | test"
  echo "  Got:     $(echo "$MSG" | head -1)"
  echo ""
  echo "  Examples:"
  echo "    feat: [story-abc123] - Add user authentication"
  echo "    review: [story-abc123] - Review user authentication"
  echo "    fix: [story-abc123] - Fix login redirect loop"
  exit 1
fi

exit 0
HOOK_EOF

chmod +x "$GIT_HOOKS_DIR/commit-msg"

echo "Hooks installed successfully."
echo "  - Pre-commit: CLAUDE.md size guard (active)"
echo "  - Pre-commit: Dependency hallucination check (commented out — uncomment after installing dep-hallucinator)"
echo "  - Pre-commit: Scope enforcement (commented out — uncomment to enable)"
echo "  - Commit-msg: Format validation (active)"
