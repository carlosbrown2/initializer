#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: source ralph.sh [--tool amp|claude] [max_iterations]

# Save shell options and restore on exit (safe for sourcing)
[[ -o nounset ]] && _RALPH_HAD_NOUNSET=1 || _RALPH_HAD_NOUNSET=0
set -u
_ralph_cleanup() {
  [[ "$_RALPH_HAD_NOUNSET" -eq 0 ]] && set +u
  unset _RALPH_HAD_NOUNSET
  unset -f _ralph_cleanup
}


# --- Dependency checks ---
command -v bd >/dev/null 2>&1 || {
  echo "Error: 'bd' (Beads CLI) is not installed."
  echo "  Install: brew install beads"
  echo "       or: npm install -g @beads/bd"
  echo "  Then run: bd init"
  return 1
}
command -v jq >/dev/null 2>&1 || {
  echo "Error: 'jq' is not installed."
  echo "  Install: brew install jq"
  return 1
}

# Parse arguments
TOOL="claude"  # Default to claude
MAX_ITERATIONS=30

while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    *)
      # Assume it's max_iterations if it's a number
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

# Validate tool choice
if [[ "$TOOL" != "amp" && "$TOOL" != "claude" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'amp' or 'claude'."
  return 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROMPT_FILE="$SCRIPT_DIR/prompt.md"
PATTERNS_FILE="$SCRIPT_DIR/patterns.md"
ARCHIVE_FILE="$SCRIPT_DIR/archive.txt"
CONFIDENCE_LOG="$SCRIPT_DIR/confidence.log"
RETRY_STATE_FILE="$SCRIPT_DIR/retry_state.json"

# Retry tracking
FAIL_COUNT=0
LAST_FAILED_BEAD=""
MAX_RETRIES=3

# Initialize patterns file if it doesn't exist
if [ ! -f "$PATTERNS_FILE" ]; then
  echo "## Codebase Patterns" > "$PATTERNS_FILE"
fi

# Initialize archive file if it doesn't exist
if [ ! -f "$ARCHIVE_FILE" ]; then
  echo "# Ralph Progress Log" > "$ARCHIVE_FILE"
  echo "Started: $(date)" >> "$ARCHIVE_FILE"
  echo "---" >> "$ARCHIVE_FILE"
fi

finish() {
  local code=$1
  local msg=$2
  echo ""
  echo "$msg"
  echo "---------------------------------------------------------------"
  if [[ $code -eq 0 ]]; then
    echo "Ralph finished successfully."
  else
    echo "Ralph exited with code $code."
  fi
  echo "---------------------------------------------------------------"
  _ralph_cleanup
  RALPH_EXIT_CODE=$code
}

# --- Confidence routing functions ---

# Extract confidence level from agent output.
# Patterns require the closing `>` so the placeholder string
# `<confidence level="HIGH|MEDIUM|LOW">` from prompt.md does not match.
parse_confidence() {
  local output="$1"
  if echo "$output" | grep -q '<confidence level="HIGH">'; then
    echo "HIGH"
  elif echo "$output" | grep -q '<confidence level="MEDIUM">'; then
    echo "MEDIUM"
  elif echo "$output" | grep -q '<confidence level="LOW">'; then
    echo "LOW"
  else
    echo ""
  fi
}

# Read auto-land policy from CLAUDE.md ## Confidence Routing section.
# Default is "all" — matches the README/CLAUDE.md template's stated default.
# (If you want a stricter default, set `auto-land: high` or `auto-land: none`
# under `## Confidence Routing` in CLAUDE.md.)
read_auto_land_policy() {
  local claude_md="$PROJECT_ROOT/CLAUDE.md"
  if [[ -f "$claude_md" ]]; then
    local policy
    policy=$(grep -A1 "## Confidence Routing" "$claude_md" | grep "auto-land:" | sed 's/.*auto-land: *//')
    echo "${policy:-all}"
  else
    echo "all"
  fi
}

# Determine if auto-land is allowed for given confidence + policy
should_auto_land() {
  local confidence="$1"
  local policy="$2"
  case "$policy" in
    all)
      echo "true"
      ;;
    high)
      [[ "$confidence" == "HIGH" ]] && echo "true" || echo "false"
      ;;
    none)
      echo "false"
      ;;
    *)
      # Unknown policy — default to the documented default ("all")
      echo "true"
      ;;
  esac
}

echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"
RALPH_EXIT_CODE=""

for i in $(seq 1 $MAX_ITERATIONS); do
  echo ""
  echo "==============================================================="
  echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL)"
  echo "==============================================================="

  # --- Write retry state for the agent to read ---
  # Detect current in-progress bead (if any)
  CURRENT_BEAD=$(bd list --status=in_progress --json 2>/dev/null | jq -r '.[0].id // empty') || true

  # If we're tracking a failed bead and a different bead is now in progress, reset
  if [[ -n "$LAST_FAILED_BEAD" && -n "$CURRENT_BEAD" && "$CURRENT_BEAD" != "$LAST_FAILED_BEAD" ]]; then
    FAIL_COUNT=0
    LAST_FAILED_BEAD=""
  fi

  # Write retry state file for the agent
  cat > "$RETRY_STATE_FILE" << RETRY_EOF
{"fail_count": $FAIL_COUNT, "bead_id": "${LAST_FAILED_BEAD:-}", "iteration": $i}
RETRY_EOF

  # --- Show upcoming work ---
  BEAD_ID=""
  BEAD_TITLE=""
  if [[ -n "$CURRENT_BEAD" ]]; then
    BEAD_ID="$CURRENT_BEAD"
    BEAD_TITLE=$(bd show "$BEAD_ID" 2>/dev/null | sed -n '2p' | sed 's/^[^·]*· //' | sed 's/  *\[●.*//')
    echo "Resuming: $BEAD_ID — $BEAD_TITLE"
  else
    BEAD_ID=$(bd ready --json 2>/dev/null | jq -r '.[0].id // empty') || true
    if [[ -n "$BEAD_ID" ]]; then
      BEAD_TITLE=$(bd show "$BEAD_ID" 2>/dev/null | sed -n '2p' | sed 's/^[^·]*· //' | sed 's/  *\[●.*//')
      echo "Current bead: $BEAD_ID — $BEAD_TITLE"
    else
      echo "No beads ready — agent will check and emit COMPLETE."
    fi
  fi
  echo "---------------------------------------------------------------"

  # Run the selected tool with the ralph prompt
  if [[ "$TOOL" == "amp" ]]; then
    OUTPUT=$(cat "$PROMPT_FILE" | amp --dangerously-allow-all 2>&1 | tee /dev/stderr) || true
  else
    # Claude Code: use --dangerously-skip-permissions for autonomous operation, --print for output
    OUTPUT=$(claude --dangerously-skip-permissions --print < "$PROMPT_FILE" 2>&1 | tee /dev/stderr) || true
  fi

  # Check for completion signal (all work done)
  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    finish 0 "Ralph completed all tasks at iteration $i of $MAX_ITERATIONS."
    break
  fi

  # Check for rate limit signal
  if echo "$OUTPUT" | grep -qi "You've hit your limit\|you have hit your limit\|rate limit\|usage limit"; then
    finish 2 "Ralph hit agent rate limit at iteration $i. Exiting gracefully."
    break
  fi

  # --- Exit signal routing ---
  BEAD_DONE=false

  # Determine the current in-progress bead for signal handling
  ACTIVE_BEAD=$(bd list --status=in_progress --json 2>/dev/null | jq -r '.[0].id // empty') || true

  if echo "$OUTPUT" | grep -q "<promise>BEAD_DONE</promise>"; then
    BEAD_DONE=true
    FAIL_COUNT=0
    LAST_FAILED_BEAD=""
    rm -f "$RETRY_STATE_FILE"
    echo "Bead completed successfully at iteration $i."

  elif echo "$OUTPUT" | grep -q "<promise>BLOCKED</promise>"; then
    # --- BLOCKED: agent hit an external/architectural blocker ---
    BLOCKED_REASON=$(echo "$OUTPUT" | sed -n 's/.*<blocked-reason>\(.*\)<\/blocked-reason>.*/\1/p' | head -1)
    BLOCKED_REASON="${BLOCKED_REASON:-No reason provided}"

    echo "BLOCKED at iteration $i: $BLOCKED_REASON"

    if [[ -n "$ACTIVE_BEAD" ]]; then
      bd update "$ACTIVE_BEAD" --status open 2>/dev/null || true
      BLOCKER_TITLE="BLOCKED: $ACTIVE_BEAD — $BLOCKED_REASON"
      bd create --title="$BLOCKER_TITLE" --type=bug --priority=1 2>/dev/null || true
      echo "  Unclaimed $ACTIVE_BEAD and filed blocker bead."
    fi

    echo "[$(date -Iseconds)] iter=$i BLOCKED bead=${ACTIVE_BEAD:-unknown} reason=$BLOCKED_REASON" >> "$CONFIDENCE_LOG"
    FAIL_COUNT=0
    LAST_FAILED_BEAD=""
    rm -f "$RETRY_STATE_FILE"

  elif echo "$OUTPUT" | grep -q "<promise>REWORK_REQUIRED</promise>"; then
    # --- REWORK_REQUIRED: prior bead's work is insufficient ---
    REWORK_REASON=$(echo "$OUTPUT" | sed -n 's/.*<rework-reason>\(.*\)<\/rework-reason>.*/\1/p' | head -1)
    REWORK_REASON="${REWORK_REASON:-No reason provided}"

    echo "REWORK REQUIRED at iteration $i: $REWORK_REASON"

    if [[ -n "$ACTIVE_BEAD" ]]; then
      # Unclaim the current bead (review/pare/compound that can't proceed)
      bd update "$ACTIVE_BEAD" --status open 2>/dev/null || true

      # Find and re-open the prerequisite bead
      PREREQ_BEAD=$(bd dep list "$ACTIVE_BEAD" 2>/dev/null | grep -oE '[a-z][-a-z0-9]*-[a-z0-9]{2,}' | head -1) || true
      if [[ -n "$PREREQ_BEAD" ]]; then
        bd update "$PREREQ_BEAD" --status open 2>/dev/null || true
        echo "  Re-opened prerequisite $PREREQ_BEAD for rework."
      fi
      echo "  Unclaimed $ACTIVE_BEAD pending rework."
    fi

    echo "[$(date -Iseconds)] iter=$i REWORK bead=${ACTIVE_BEAD:-unknown} reason=$REWORK_REASON" >> "$CONFIDENCE_LOG"
    FAIL_COUNT=0
    LAST_FAILED_BEAD=""
    rm -f "$RETRY_STATE_FILE"

  else
    echo "WARNING: No exit signal detected at iteration $i. Agent may have stopped unexpectedly."

    # --- Retry tracking ---
    FAILED_BEAD="$ACTIVE_BEAD"

    if [[ -n "$FAILED_BEAD" ]]; then
      if [[ "$FAILED_BEAD" == "$LAST_FAILED_BEAD" ]]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
      else
        # New bead failed — start tracking from 1
        FAIL_COUNT=1
        LAST_FAILED_BEAD="$FAILED_BEAD"
      fi

      echo "Retry tracking: bead=$FAILED_BEAD fail_count=$FAIL_COUNT/$MAX_RETRIES"

      # Safety-net escalation: if agent failed MAX_RETRIES times without escalating
      if [[ $FAIL_COUNT -ge $MAX_RETRIES ]]; then
        echo "ESCALATION (safety net): Bead $FAILED_BEAD failed $FAIL_COUNT times."
        echo "  Unclaiming bead and filing blocker..."

        # Unclaim the bead
        bd update "$FAILED_BEAD" --status open 2>/dev/null || true

        # File a blocker bead
        BLOCKER_TITLE="BLOCKED: $FAILED_BEAD failed $FAIL_COUNT times — needs manual investigation"
        bd create --title="$BLOCKER_TITLE" --type=bug --priority=1 2>/dev/null || true

        # Log to confidence log
        echo "[$(date -Iseconds)] iter=$i ESCALATION bead=$FAILED_BEAD fail_count=$FAIL_COUNT" >> "$CONFIDENCE_LOG"

        # Reset tracking
        FAIL_COUNT=0
        LAST_FAILED_BEAD=""
        rm -f "$RETRY_STATE_FILE"
      fi
    fi
  fi

  # --- Gate result extraction ---
  GATE_RESULT="skipped"
  if echo "$OUTPUT" | grep -q '<gate-result>PASS</gate-result>'; then
    GATE_RESULT="PASS"
  elif echo "$OUTPUT" | grep -q '<gate-result>FAIL</gate-result>'; then
    GATE_RESULT="FAIL"
  fi

  # Persist the agent's self-reported gate result so the pre-push hook
  # (installed by scripts/hooks/install.sh) can detect divergence when the
  # agent claimed PASS but the real gate command fails. This file is
  # gitignored; it is local runtime state, not a committed artifact.
  printf '%s\n' "$GATE_RESULT" > "$PROJECT_ROOT/.last-gate-result"

  # --- Confidence routing ---
  CONFIDENCE=$(parse_confidence "$OUTPUT")
  if [[ -n "$CONFIDENCE" ]]; then
    POLICY=$(read_auto_land_policy)
    AUTO_LAND=$(should_auto_land "$CONFIDENCE" "$POLICY")

    # Log every routing decision for auditability
    echo "[$(date -Iseconds)] iter=$i bead=${ACTIVE_BEAD:-unknown} bead_done=$BEAD_DONE confidence=$CONFIDENCE policy=$POLICY auto_land=$AUTO_LAND gate_result=$GATE_RESULT" >> "$CONFIDENCE_LOG"

    if [[ "$AUTO_LAND" == "true" ]]; then
      echo "Auto-land: confidence=$CONFIDENCE, policy=$POLICY"
    else
      echo "Pausing for human review: confidence=$CONFIDENCE, policy=$POLICY"
      echo "  Press Enter to continue or Ctrl+C to abort..."
      read -r
    fi
  else
    echo "[$(date -Iseconds)] iter=$i bead=${ACTIVE_BEAD:-unknown} bead_done=$BEAD_DONE confidence=NONE (no signal detected) gate_result=$GATE_RESULT" >> "$CONFIDENCE_LOG"
  fi

  echo "Iteration $i complete. Continuing..."
  sleep 2
done

if [[ -z "$RALPH_EXIT_CODE" ]]; then
  finish 1 "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks. Check $ARCHIVE_FILE for status."
fi
