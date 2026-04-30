#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: source ralph.sh [--tool amp|claude] [max_iterations]
#
# State hygiene: every script-scope variable is prefixed with `_RALPH_` and
# explicitly unset in `_ralph_cleanup` so sourcing the script does not leak
# state into the caller's shell. Every early `return` path calls cleanup
# before exiting so `set -u` (applied here) does not persist to the caller.

# Save shell options and restore on exit (safe for sourcing)
[[ -o nounset ]] && _RALPH_HAD_NOUNSET=1 || _RALPH_HAD_NOUNSET=0
set -u

_ralph_cleanup() {
  [[ "${_RALPH_HAD_NOUNSET:-0}" -eq 0 ]] && set +u
  unset _RALPH_HAD_NOUNSET
  unset _RALPH_TOOL _RALPH_MAX_ITERATIONS
  unset _RALPH_SCRIPT_DIR _RALPH_PROJECT_ROOT
  unset _RALPH_PROMPT_FILE _RALPH_PATTERNS_FILE _RALPH_ARCHIVE_FILE
  unset _RALPH_CONFIDENCE_LOG _RALPH_RETRY_STATE_FILE _RALPH_LIB
  unset _RALPH_PARSERS _RALPH_GATE_CMD
  unset _RALPH_FAIL_COUNT _RALPH_LAST_FAILED_BEAD _RALPH_MAX_RETRIES
  unset _RALPH_I _RALPH_CURRENT_BEAD _RALPH_ACTIVE_BEAD
  unset _RALPH_BEAD_ID _RALPH_BEAD_TITLE _RALPH_OUTPUT
  unset _RALPH_BEAD_TYPE _RALPH_BEAD_DESCRIPTION _RALPH_COMPLETED_SUMMARY
  unset _RALPH_BEAD_DONE _RALPH_BLOCKED_REASON _RALPH_REWORK_REASON
  unset _RALPH_PREREQ_BEAD _RALPH_BLOCKER_TITLE
  unset _RALPH_GATE_RESULT _RALPH_CONFIDENCE _RALPH_POLICY _RALPH_AUTO_LAND
  unset _RALPH_FOLLOWUP_NUMER _RALPH_FOLLOWUP_DENOM _RALPH_FOLLOWUP_RATIO
  unset _RALPH_DIFF_LINES _RALPH_TOUCHED_HOOKS _RALPH_TOUCHED_CLAUDE_MD
  unset _RALPH_HEAD_FILES
  unset _RALPH_HEAD_AT_ITER_START _RALPH_HEAD_AT_BEAD_DONE
  unset _RALPH_STALE_HEAD _RALPH_STALE_HEAD_FIELD
  unset _RALPH_FAILED_BEAD _RALPH_RETRY_STATE _RALPH_RETRY_REST _RALPH_RETRY_ACTION
  unset _RALPH_GOVERNANCE_JSON
  unset -f _ralph_cleanup _ralph_bead_in_progress _ralph_bead_ready _ralph_bead_title
  unset -f _ralph_load_bead_meta _ralph_sanitize_log_field
  unset -f _ralph_surface_stale_governance
}

# --- Bead id extractors ----------------------------------------------------
# Single source of truth for how this loop reads bead state from the `bd` CLI.
# install.sh's pre-commit hook calls the same shapes via its own sourced lib
# (see bd_bead_in_progress in scripts/hooks/parsers.sh) so the two cannot
# disagree about what "there is an in-progress bead" means. Both use --json
# so a `bd` TUI format change does not silently flip the result. Extraction
# failure (non-zero exit OR non-parseable JSON) prints nothing — callers
# decide whether empty means "no bead" (benign) or "bd is broken" (block).

_ralph_bead_in_progress() {
  local out
  out=$(bd list --status=in_progress --json 2>/dev/null) || return 0
  jq -r '.[0].id // empty' <<<"$out" 2>/dev/null || return 0
}

_ralph_bead_ready() {
  local out
  out=$(bd ready --json 2>/dev/null) || return 0
  jq -r '.[0].id // empty' <<<"$out" 2>/dev/null || return 0
}

_ralph_bead_title() {
  local id="$1"
  # Prefer --json; fall back to the brittle line-2 parse if bd lacks JSON.
  # jq path normalizes bd <0.49 (object) and bd >=0.49 (array-of-one) so a
  # version bump does not silently empty the title.
  local j
  if j=$(bd show "$id" --json 2>/dev/null) && [ -n "$j" ]; then
    jq -r '(if type == "array" then .[0] else . end).title // empty' <<<"$j" 2>/dev/null
    return 0
  fi
  bd show "$id" 2>/dev/null | sed -n '2p' | sed 's/^[^·]*· //' | sed 's/  *\[●.*//'
}

# Hydrate _RALPH_BEAD_TYPE / _RALPH_BEAD_TITLE / _RALPH_BEAD_DESCRIPTION
# from a single `bd show <id> --json` call (three separate calls would
# triple per-iter shell-out cost on a slow bd). Type is the logical loop
# taxonomy parsed from the title prefix; falls back to bd's `.issue_type`
# when no impl/review/pare/compound/research keyword matches.
_ralph_load_bead_meta() {
  local id="$1"
  _RALPH_BEAD_TYPE=""
  _RALPH_BEAD_TITLE=""
  _RALPH_BEAD_DESCRIPTION=""
  local j issue_type
  j=$(bd show "$id" --json 2>/dev/null) || return 0
  [ -n "$j" ] || return 0
  _RALPH_BEAD_TITLE=$(jq -r '(if type == "array" then .[0] else . end).title // empty' <<<"$j" 2>/dev/null) || _RALPH_BEAD_TITLE=""
  _RALPH_BEAD_DESCRIPTION=$(jq -r '(if type == "array" then .[0] else . end).description // empty' <<<"$j" 2>/dev/null) || _RALPH_BEAD_DESCRIPTION=""
  issue_type=$(jq -r '(if type == "array" then .[0] else . end).issue_type // empty' <<<"$j" 2>/dev/null) || issue_type=""
  if [[ "$_RALPH_BEAD_TITLE" =~ (^|[[:space:]])(impl|review|pare|pare-down|compound|research)[[:space:]]*: ]]; then
    _RALPH_BEAD_TYPE="${BASH_REMATCH[2]}"
  else
    _RALPH_BEAD_TYPE="$issue_type"
  fi
}

# Normalize free-form text (titles, commit subjects, descriptions) for the
# confidence.log line. Collapses whitespace, replaces `"` with `'` so the
# value is safe inside the surrounding double quotes, truncates at 160
# chars with `...` so a long description does not push real fields out of
# view. The line-oriented parsers in scripts/hooks/parsers.sh would
# silently corrupt their output on a smuggled newline.
_ralph_sanitize_log_field() {
  local s="$1"
  # tr pipeline (not parameter expansion) — bash's `${s//\"/'}` form is not
  # parseable because the `'` opens a string the parser cannot match.
  # First tr: whitespace → space. Second tr: `"` → `'` (so the value is
  # safe inside the surrounding `title="…"` log field). Third tr: squeeze
  # adjacent spaces so multi-line input collapses to a clean token-stream.
  s=$(printf '%s' "$s" | tr '[:space:]' ' ' | tr '"' "'" | tr -s ' ')
  s="${s# }"
  s="${s% }"
  if [ "${#s}" -gt 160 ]; then
    s="${s:0:157}..."
  fi
  printf '%s' "$s"
}

# Surface stale (>3d) governance beads above the iter banner so the
# operator sees the loop's own audit instructions before the agent claims
# its next bead. Pure surfacing — the >7d hard force-LOW rule lives in
# governance_bead_max_age_days (lib.sh). bd / jq failures silently no-op:
# this is best-effort visibility, not a correctness gate.
_ralph_surface_stale_governance() {
  local json="$1"
  [[ -n "$json" ]] || return 0
  local lines
  lines=$(jq -r --arg re "$GOVERNANCE_TITLE_REGEX" --argjson now "$(date +%s)" "
    $BD_DATE_TO_EPOCH_JQ_DEF
    [.[]
      | select(.title | test(\$re))
      | ((\$now - (.created_at | bd_date_to_epoch)) / 86400 | floor) as \$age
      | select(\$age > 3)
      | \"  \(.id) (\(\$age)d) \(.title)\"
    ] | .[]
  " <<<"$json" 2>/dev/null) || return 0
  [[ -n "$lines" ]] || return 0
  echo "⚠ Stale governance:"
  echo "$lines"
}

# --- Dependency checks ---
command -v bd >/dev/null 2>&1 || {
  echo "Error: 'bd' (Beads CLI) is not installed."
  echo "  Install: brew install beads"
  echo "       or: npm install -g @beads/bd"
  echo "  Then run: bd init"
  _ralph_cleanup
  return 1
}
command -v jq >/dev/null 2>&1 || {
  echo "Error: 'jq' is not installed."
  echo "  Install: brew install jq"
  _ralph_cleanup
  return 1
}

# Parse arguments
_RALPH_TOOL="claude"
_RALPH_MAX_ITERATIONS=30

while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)
      _RALPH_TOOL="$2"
      shift 2
      ;;
    --tool=*)
      _RALPH_TOOL="${1#*=}"
      shift
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        _RALPH_MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

if [[ "$_RALPH_TOOL" != "amp" && "$_RALPH_TOOL" != "claude" ]]; then
  echo "Error: Invalid tool '$_RALPH_TOOL'. Must be 'amp' or 'claude'."
  _ralph_cleanup
  return 1
fi

_RALPH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_RALPH_PROJECT_ROOT="$(cd "$_RALPH_SCRIPT_DIR/../.." && pwd)"
_RALPH_PROMPT_FILE="$_RALPH_SCRIPT_DIR/prompt.md"
_RALPH_PATTERNS_FILE="$_RALPH_SCRIPT_DIR/patterns.md"
_RALPH_ARCHIVE_FILE="$_RALPH_SCRIPT_DIR/archive.txt"
_RALPH_CONFIDENCE_LOG="$_RALPH_SCRIPT_DIR/confidence.log"
_RALPH_RETRY_STATE_FILE="$_RALPH_SCRIPT_DIR/retry_state.json"

# Source routing functions (compute_confidence, read_auto_land_policy,
# should_auto_land, compute_retry_state, extract_prereq_bead_id, run_gate)
# so tests/hooks/ralph.bats exercises the same definitions the loop uses.
_RALPH_LIB="$_RALPH_SCRIPT_DIR/lib.sh"
if [ ! -f "$_RALPH_LIB" ]; then
  echo "Error: scripts/ralph/lib.sh not found at $_RALPH_LIB"
  _ralph_cleanup
  return 1
fi
# shellcheck source=/dev/null
source "$_RALPH_LIB"

# Source gate_command_extract from parsers.sh. ralph.sh now runs the
# verification gate itself after BEAD_DONE (replacing the prior design
# where the agent self-reported via `<gate-result>`), so we need the
# single-source extractor the pre-push hook and bats suite also use.
# Sourcing this file also makes a future edit to the extraction logic
# land in all three callers at once.
_RALPH_PARSERS="$_RALPH_SCRIPT_DIR/../hooks/parsers.sh"
if [ ! -f "$_RALPH_PARSERS" ]; then
  echo "Error: scripts/hooks/parsers.sh not found at $_RALPH_PARSERS"
  _ralph_cleanup
  return 1
fi
# shellcheck source=/dev/null
source "$_RALPH_PARSERS"

_RALPH_GATE_CMD=$(gate_command_extract "$_RALPH_PROJECT_ROOT/CLAUDE.md")
if [ -z "$_RALPH_GATE_CMD" ]; then
  echo "Error: no verification gate found under '## Verification Gate' in CLAUDE.md"
  _ralph_cleanup
  return 1
fi

# Retry tracking
_RALPH_FAIL_COUNT=0
_RALPH_LAST_FAILED_BEAD=""
_RALPH_MAX_RETRIES=3

# Initialize patterns file if it doesn't exist
if [ ! -f "$_RALPH_PATTERNS_FILE" ]; then
  echo "## Codebase Patterns" > "$_RALPH_PATTERNS_FILE"
fi

# Initialize archive file if it doesn't exist
if [ ! -f "$_RALPH_ARCHIVE_FILE" ]; then
  echo "# Ralph Progress Log" > "$_RALPH_ARCHIVE_FILE"
  echo "Started: $(date)" >> "$_RALPH_ARCHIVE_FILE"
  echo "---" >> "$_RALPH_ARCHIVE_FILE"
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
  RALPH_EXIT_CODE=$code
  _ralph_cleanup
}

echo "Starting Ralph - Tool: $_RALPH_TOOL - Max iterations: $_RALPH_MAX_ITERATIONS"
RALPH_EXIT_CODE=""

for _RALPH_I in $(seq 1 "$_RALPH_MAX_ITERATIONS"); do
  echo ""
  echo "==============================================================="
  echo "  Ralph Iteration $_RALPH_I of $_RALPH_MAX_ITERATIONS ($_RALPH_TOOL)"
  echo "==============================================================="

  # Capture the active bead ONCE at the top of the iteration and reuse it
  # everywhere below. Previously a second `bd list` ran after the agent
  # returned — by which point the agent had already `bd close`d the bead on
  # BEAD_DONE, so the snapshot came back empty and every successful iteration
  # was logged as `bead=unknown`. See confidence.log entries from 2026-04-21
  # for the signature pattern: iter=1..12 all bead=unknown on BEAD_DONE,
  # iter=2 and iter=8 show real ids because the agent stalled without
  # closing. One pre-run capture fixes both cases.
  _RALPH_ACTIVE_BEAD=$(_ralph_bead_in_progress)

  # If we're tracking a failed bead and a different bead is now in progress, reset
  if [[ -n "$_RALPH_LAST_FAILED_BEAD" && -n "$_RALPH_ACTIVE_BEAD" && "$_RALPH_ACTIVE_BEAD" != "$_RALPH_LAST_FAILED_BEAD" ]]; then
    _RALPH_FAIL_COUNT=0
    _RALPH_LAST_FAILED_BEAD=""
  fi

  # Write retry state file for the agent
  cat > "$_RALPH_RETRY_STATE_FILE" << RETRY_EOF
{"fail_count": $_RALPH_FAIL_COUNT, "bead_id": "${_RALPH_LAST_FAILED_BEAD:-}", "iteration": $_RALPH_I}
RETRY_EOF

  # --- Show upcoming work ---
  # Hydrate type/title/description from a single bd show call so the banner,
  # the confidence.log line, and the iteration footer all read from the same
  # snapshot. _RALPH_BEAD_ID is set from either the resumed in-progress bead
  # or _ralph_bead_ready so it always names the bead the agent will work on.
  _RALPH_BEAD_ID=""
  _RALPH_BEAD_TITLE=""
  _RALPH_BEAD_TYPE=""
  _RALPH_BEAD_DESCRIPTION=""
  _RALPH_COMPLETED_SUMMARY=""
  if [[ -n "$_RALPH_ACTIVE_BEAD" ]]; then
    _RALPH_BEAD_ID="$_RALPH_ACTIVE_BEAD"
  else
    _RALPH_BEAD_ID=$(_ralph_bead_ready)
  fi
  if [[ -n "$_RALPH_BEAD_ID" ]]; then
    _ralph_load_bead_meta "$_RALPH_BEAD_ID"
    echo "[$_RALPH_BEAD_TYPE] — $_RALPH_BEAD_TITLE"
    [[ -n "$_RALPH_BEAD_DESCRIPTION" ]] && echo "Description: $_RALPH_BEAD_DESCRIPTION"
  else
    echo "No beads ready — agent will check and emit COMPLETE."
  fi
  # Snapshot the open-bead list once per iter; both the surfacing helper
  # above (>3d visibility) and the >7d force-LOW check below read from
  # the same JSON so a bead the agent closes mid-iter cannot make the
  # governance routing disagree with what the operator was just shown.
  _RALPH_GOVERNANCE_JSON=$(bd list --status=open --json 2>/dev/null || echo "[]")
  _ralph_surface_stale_governance "$_RALPH_GOVERNANCE_JSON"
  echo "---------------------------------------------------------------"

  # Snapshot HEAD before the agent runs. compute_head_unchanged_for_bead_done
  # (lib.sh) compares this against the post-iter HEAD on BEAD_DONE detection
  # to catch a BEAD_DONE without a new commit — every per-iter signal below
  # (diff_lines, touched_hooks, touched_claude_md) reads HEAD, so a stale-
  # HEAD iter would silently grade the prior bead's commit. The empty-string
  # fallback handles a pre-first-commit repo (rev-parse exits non-zero) so
  # `set -u` does not crash the loop on a fresh checkout.
  _RALPH_HEAD_AT_ITER_START=$(git -C "$_RALPH_PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")

  # Run the selected tool with the ralph prompt
  if [[ "$_RALPH_TOOL" == "amp" ]]; then
    _RALPH_OUTPUT=$(amp --dangerously-allow-all < "$_RALPH_PROMPT_FILE" 2>&1 | tee /dev/stderr) || true
  else
    # Claude Code: --dangerously-skip-permissions for autonomous operation, --print for output
    _RALPH_OUTPUT=$(claude --dangerously-skip-permissions --print < "$_RALPH_PROMPT_FILE" 2>&1 | tee /dev/stderr) || true
  fi

  # Check for completion signal (all work done)
  if echo "$_RALPH_OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    finish 0 "Ralph completed all tasks at iteration $_RALPH_I of $_RALPH_MAX_ITERATIONS."
    break
  fi

  # Check for rate limit signal
  if echo "$_RALPH_OUTPUT" | grep -qi "You've hit your limit\|you have hit your limit\|rate limit\|usage limit"; then
    finish 2 "Ralph hit agent rate limit at iteration $_RALPH_I. Exiting gracefully."
    break
  fi

  # --- Exit signal routing ---
  _RALPH_BEAD_DONE=false
  _RALPH_STALE_HEAD=false

  if echo "$_RALPH_OUTPUT" | grep -q "<promise>BEAD_DONE</promise>"; then
    _RALPH_BEAD_DONE=true
    _RALPH_FAIL_COUNT=0
    _RALPH_LAST_FAILED_BEAD=""
    rm -f "$_RALPH_RETRY_STATE_FILE"

    # Stale-HEAD check: agent emitted BEAD_DONE — did HEAD actually move?
    # If not, every per-iter signal in the confidence block below would
    # grade the prior bead's commit. compute_head_unchanged_for_bead_done
    # (lib.sh) returns 0 when pre == post; we record _RALPH_STALE_HEAD=true
    # for the gate-result block to act on and the confidence.log line to
    # surface as `stale_head=true` for future audits.
    _RALPH_HEAD_AT_BEAD_DONE=$(git -C "$_RALPH_PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")
    if compute_head_unchanged_for_bead_done "$_RALPH_HEAD_AT_ITER_START" "$_RALPH_HEAD_AT_BEAD_DONE"; then
      _RALPH_STALE_HEAD=true
      # Stale-HEAD: HEAD did not move, so `git log -1 --pretty=%s` would
      # return the *prior* bead's subject — exactly the cross-bead
      # contamination the stale-HEAD detector exists to flag. Replace with
      # the marker so the log line carries the diagnosis, not the wrong work.
      _RALPH_COMPLETED_SUMMARY="(no new commit — stale HEAD)"
      echo "Stale HEAD detected: BEAD_DONE emitted at iteration $_RALPH_I without a new commit."
    else
      _RALPH_COMPLETED_SUMMARY=$(git -C "$_RALPH_PROJECT_ROOT" log -1 --pretty=%s 2>/dev/null || echo "")
      echo "Bead completed successfully at iteration $_RALPH_I."
    fi

  elif echo "$_RALPH_OUTPUT" | grep -q "<promise>BLOCKED</promise>"; then
    _RALPH_BLOCKED_REASON=$(echo "$_RALPH_OUTPUT" | sed -n 's/.*<blocked-reason>\(.*\)<\/blocked-reason>.*/\1/p' | head -1)
    _RALPH_BLOCKED_REASON="${_RALPH_BLOCKED_REASON:-No reason provided}"

    echo "BLOCKED at iteration $_RALPH_I: $_RALPH_BLOCKED_REASON"

    if [[ -n "$_RALPH_ACTIVE_BEAD" ]]; then
      bd update "$_RALPH_ACTIVE_BEAD" --status open 2>/dev/null || true
      _RALPH_BLOCKER_TITLE="BLOCKED: $_RALPH_ACTIVE_BEAD — $_RALPH_BLOCKED_REASON"
      bd create --title="$_RALPH_BLOCKER_TITLE" --type=bug --priority=1 2>/dev/null || true
      echo "  Unclaimed $_RALPH_ACTIVE_BEAD and filed blocker bead."
    fi

    echo "[$(date -Iseconds)] iter=$_RALPH_I BLOCKED bead=${_RALPH_ACTIVE_BEAD:-unknown} bead_type=$_RALPH_BEAD_TYPE reason=$_RALPH_BLOCKED_REASON title=\"$(_ralph_sanitize_log_field "$_RALPH_BEAD_TITLE")\"" >> "$_RALPH_CONFIDENCE_LOG"
    _RALPH_FAIL_COUNT=0
    _RALPH_LAST_FAILED_BEAD=""
    rm -f "$_RALPH_RETRY_STATE_FILE"

  elif echo "$_RALPH_OUTPUT" | grep -q "<promise>REWORK_REQUIRED</promise>"; then
    _RALPH_REWORK_REASON=$(echo "$_RALPH_OUTPUT" | sed -n 's/.*<rework-reason>\(.*\)<\/rework-reason>.*/\1/p' | head -1)
    _RALPH_REWORK_REASON="${_RALPH_REWORK_REASON:-No reason provided}"

    echo "REWORK REQUIRED at iteration $_RALPH_I: $_RALPH_REWORK_REASON"

    if [[ -n "$_RALPH_ACTIVE_BEAD" ]]; then
      bd update "$_RALPH_ACTIVE_BEAD" --status open 2>/dev/null || true

      _RALPH_PREREQ_BEAD=$(bd dep list "$_RALPH_ACTIVE_BEAD" 2>/dev/null | extract_prereq_bead_id "$_RALPH_ACTIVE_BEAD") || true
      if [[ -n "$_RALPH_PREREQ_BEAD" ]]; then
        bd update "$_RALPH_PREREQ_BEAD" --status open 2>/dev/null || true
        echo "  Re-opened prerequisite $_RALPH_PREREQ_BEAD for rework."
      fi
      echo "  Unclaimed $_RALPH_ACTIVE_BEAD pending rework."
    fi

    echo "[$(date -Iseconds)] iter=$_RALPH_I REWORK bead=${_RALPH_ACTIVE_BEAD:-unknown} bead_type=$_RALPH_BEAD_TYPE reason=$_RALPH_REWORK_REASON title=\"$(_ralph_sanitize_log_field "$_RALPH_BEAD_TITLE")\"" >> "$_RALPH_CONFIDENCE_LOG"
    _RALPH_FAIL_COUNT=0
    _RALPH_LAST_FAILED_BEAD=""
    rm -f "$_RALPH_RETRY_STATE_FILE"

  else
    echo "WARNING: No exit signal detected at iteration $_RALPH_I. Agent may have stopped unexpectedly."

    _RALPH_FAILED_BEAD="$_RALPH_ACTIVE_BEAD"

    if [[ -n "$_RALPH_FAILED_BEAD" ]]; then
      _RALPH_RETRY_STATE=$(compute_retry_state "$_RALPH_FAILED_BEAD" "$_RALPH_LAST_FAILED_BEAD" "$_RALPH_FAIL_COUNT" "$_RALPH_MAX_RETRIES")
      _RALPH_FAIL_COUNT="${_RALPH_RETRY_STATE%%|*}"
      _RALPH_RETRY_REST="${_RALPH_RETRY_STATE#*|}"
      _RALPH_LAST_FAILED_BEAD="${_RALPH_RETRY_REST%%|*}"
      _RALPH_RETRY_ACTION="${_RALPH_RETRY_STATE##*|}"

      echo "Retry tracking: bead=$_RALPH_FAILED_BEAD fail_count=$_RALPH_FAIL_COUNT/$_RALPH_MAX_RETRIES"

      if [[ "$_RALPH_RETRY_ACTION" == "escalate" ]]; then
        echo "ESCALATION (safety net): Bead $_RALPH_FAILED_BEAD failed $_RALPH_FAIL_COUNT times."
        echo "  Unclaiming bead and filing blocker..."

        bd update "$_RALPH_FAILED_BEAD" --status open 2>/dev/null || true

        _RALPH_BLOCKER_TITLE="BLOCKED: $_RALPH_FAILED_BEAD failed $_RALPH_FAIL_COUNT times — needs manual investigation"
        bd create --title="$_RALPH_BLOCKER_TITLE" --type=bug --priority=1 2>/dev/null || true

        echo "[$(date -Iseconds)] iter=$_RALPH_I ESCALATION bead=$_RALPH_FAILED_BEAD bead_type=$_RALPH_BEAD_TYPE fail_count=$_RALPH_FAIL_COUNT title=\"$(_ralph_sanitize_log_field "$_RALPH_BEAD_TITLE")\"" >> "$_RALPH_CONFIDENCE_LOG"

        _RALPH_FAIL_COUNT=0
        _RALPH_LAST_FAILED_BEAD=""
        rm -f "$_RALPH_RETRY_STATE_FILE"
      fi
    fi
  fi

  # --- Gate result (bash-run, not agent self-report) ---
  # On BEAD_DONE, re-run the gate from bash and bind .last-gate-result to
  # the real exit code. Replaces the prior design where the agent emitted
  # `<gate-result>` and we grep-parsed the tag — a self-report the agent
  # could skip, misquote, or hallucinate. See run_gate in lib.sh for the
  # rationale and scripts/hooks/install.sh pre-push for the defense-in-
  # depth re-run on push.
  #
  # On non-BEAD_DONE iterations (BLOCKED, REWORK, no-signal), clear the
  # result file so a subsequent push does not trust a stale PASS from a
  # prior iteration. The pre-push hook still runs the gate itself; this
  # just removes a misleading informational artifact.
  _RALPH_GATE_RESULT="skipped"
  if [[ "$_RALPH_BEAD_DONE" == "true" ]]; then
    if [[ "$_RALPH_STALE_HEAD" == "true" ]]; then
      # Stale-HEAD BEAD_DONE: HEAD did not move during the iter, so the gate
      # would grade the prior bead's tree. Skip the gate run and write FAIL
      # directly — pairing the detection (lib.sh helper) with the consequence
      # (confidence routes to LOW via gate_result=FAIL) here, where the rest
      # of compute_confidence's inputs are in scope.
      printf 'FAIL\n' > "$_RALPH_PROJECT_ROOT/.last-gate-result"
      _RALPH_GATE_RESULT="FAIL"
    elif run_gate "$_RALPH_GATE_CMD" "$_RALPH_PROJECT_ROOT/.last-gate-result"; then
      _RALPH_GATE_RESULT="PASS"
    else
      _RALPH_GATE_RESULT="FAIL"
    fi
  else
    rm -f "$_RALPH_PROJECT_ROOT/.last-gate-result"
  fi

  # --- Confidence routing (derived from signals, not agent self-grade) ---
  # compute_confidence (lib.sh) reads the observable outcome of this iteration
  # and returns HIGH/MEDIUM/LOW deterministically. Replaces the prior
  # parse_confidence / parse_confidence_bead_done pair that extracted an
  # agent-emitted tag — a prediction the agent made about its work rather
  # than a measurement of it. On non-BEAD_DONE iterations (BLOCKED, REWORK,
  # no-signal) there is no committed work to grade, so confidence is left
  # empty and the block below logs `confidence=NONE` without routing.
  _RALPH_CONFIDENCE=""
  if [[ "$_RALPH_BEAD_DONE" == "true" ]]; then
    # Signals come from the bead's commit (HEAD). The agent is required to
    # `bd close` and commit before emitting BEAD_DONE, so HEAD is this
    # bead's work. git-show failures default to benign values so a missing
    # git history (tests, early bootstrap) does not crash the loop.
    _RALPH_DIFF_LINES=$(git -C "$_RALPH_PROJECT_ROOT" show --numstat HEAD 2>/dev/null \
      | awk '{ s += $1 + $2 } END { print s + 0 }')
    _RALPH_HEAD_FILES=$(git -C "$_RALPH_PROJECT_ROOT" show --name-only --pretty=format: HEAD 2>/dev/null || true)
    if echo "$_RALPH_HEAD_FILES" | grep -q '^scripts/hooks/'; then
      _RALPH_TOUCHED_HOOKS=true
    else
      _RALPH_TOUCHED_HOOKS=false
    fi
    # Scope the touched_claude_md signal to edits *outside* `## Discovered
    # Patterns`. Compound beads append model-tagged entries to that section
    # by design; an append-only output edit redefines no rule the gate runs,
    # so it should not downgrade confidence. Edits to `## Invariants` or
    # `## Verification Gate` still trigger here. See lib.sh
    # claude_md_touched_outside_patterns.
    if claude_md_touched_outside_patterns "$_RALPH_PROJECT_ROOT"; then
      _RALPH_TOUCHED_CLAUDE_MD=true
    else
      _RALPH_TOUCHED_CLAUDE_MD=false
    fi
    # loop_saturation: count `Phase % follow-up:` titles among the last 5
    # closed beads. AND-suppressor (no `Phase N impl:` or `integration-` in
    # the same window) is baked in here by passing 0 as the ratio — the
    # function takes one value, so the conjunction lives at the call site.
    # Raw N/5 still goes to confidence.log so audits see the underlying count.
    _RALPH_FOLLOWUP_NUMER=0
    _RALPH_FOLLOWUP_DENOM=5
    _RALPH_FOLLOWUP_RATIO=0
    _RALPH_RECENT_CLOSED_TITLES=$(bd list --status=closed --json 2>/dev/null \
      | jq -r 'sort_by(.closed_at) | reverse | .[0:5] | .[].title' 2>/dev/null || true)
    if [[ -n "$_RALPH_RECENT_CLOSED_TITLES" ]]; then
      _RALPH_FOLLOWUP_NUMER=$(echo "$_RALPH_RECENT_CLOSED_TITLES" | grep -cE '^Phase .* follow-up:' || true)
      _RALPH_HAS_PHASE_OR_INT=$(echo "$_RALPH_RECENT_CLOSED_TITLES" | grep -cE '^(Phase [0-9]+ impl:|integration-)' || true)
      if [[ "$_RALPH_HAS_PHASE_OR_INT" -eq 0 ]]; then
        _RALPH_FOLLOWUP_RATIO=$(awk -v n="$_RALPH_FOLLOWUP_NUMER" -v d="$_RALPH_FOLLOWUP_DENOM" 'BEGIN { if (d > 0) printf "%.4f", n/d; else print "0" }')
      fi
    fi
    unset _RALPH_RECENT_CLOSED_TITLES _RALPH_HAS_PHASE_OR_INT
    _RALPH_CONFIDENCE=$(compute_confidence \
      "$_RALPH_GATE_RESULT" "$_RALPH_DIFF_LINES" "$_RALPH_TOUCHED_HOOKS" \
      "$_RALPH_TOUCHED_CLAUDE_MD" "$_RALPH_FOLLOWUP_RATIO")
    # LOOP_SATURATION line on the saturation-downgrade path: same trigger as
    # compute_confidence's loop_saturation axis. Separate line so a future
    # audit can grep LOOP_SATURATION directly.
    if [[ "$(awk -v r="$_RALPH_FOLLOWUP_RATIO" 'BEGIN { print (r >= 0 && r <= 1 && r > 0.6) ? 1 : 0 }')" == "1" ]]; then
      echo "[$(date -Iseconds)] iter=$_RALPH_I LOOP_SATURATION followup_ratio=$_RALPH_FOLLOWUP_NUMER/$_RALPH_FOLLOWUP_DENOM bead=${_RALPH_BEAD_ID:-unknown}" >> "$_RALPH_CONFIDENCE_LOG"
    fi
    # Force LOW when a governance bead has aged past the cut. Override
    # post-compute_confidence (not as a 5th axis) so the rest of the
    # routing matrix still shows up in confidence.log for the audit trail.
    if governance_bead_max_age_days "$_RALPH_GOVERNANCE_JSON"; then
      _RALPH_CONFIDENCE="LOW"
    fi
  fi
  # Build the optional `stale_head=true` field once so both log lines below
  # carry the same shape. Emitted only on stale-HEAD iters so a future audit
  # can `grep stale_head=true confidence.log` directly without false hits.
  _RALPH_STALE_HEAD_FIELD=""
  if [[ "$_RALPH_STALE_HEAD" == "true" ]]; then
    _RALPH_STALE_HEAD_FIELD=" stale_head=true"
  fi

  if [[ -n "$_RALPH_CONFIDENCE" ]]; then
    _RALPH_POLICY=$(read_auto_land_policy "$_RALPH_PROJECT_ROOT/CLAUDE.md")
    _RALPH_AUTO_LAND=$(should_auto_land "$_RALPH_CONFIDENCE" "$_RALPH_POLICY")

    # _RALPH_BEAD_ID, not _RALPH_ACTIVE_BEAD: the latter is empty whenever the
    # iter started with no in-progress bead and the agent picked up a fresh
    # bead via _ralph_bead_ready during the iter — so logging it printed
    # `bead=unknown` for almost every successful BEAD_DONE iter, and
    # archive_schema_check (which filters bead=unknown out) silently passed.
    # _RALPH_BEAD_ID is set at the iter top from either the resumed
    # _RALPH_ACTIVE_BEAD or _ralph_bead_ready, so it always names the bead
    # the agent will work on. Same fix in the confidence=NONE branch below.
    echo "[$(date -Iseconds)] iter=$_RALPH_I bead=${_RALPH_BEAD_ID:-unknown} bead_type=$_RALPH_BEAD_TYPE bead_done=$_RALPH_BEAD_DONE confidence=$_RALPH_CONFIDENCE policy=$_RALPH_POLICY auto_land=$_RALPH_AUTO_LAND gate_result=$_RALPH_GATE_RESULT followup_ratio=${_RALPH_FOLLOWUP_NUMER:-0}/${_RALPH_FOLLOWUP_DENOM:-5}${_RALPH_STALE_HEAD_FIELD} title=\"$(_ralph_sanitize_log_field "$_RALPH_BEAD_TITLE")\" completed=\"$(_ralph_sanitize_log_field "$_RALPH_COMPLETED_SUMMARY")\"" >> "$_RALPH_CONFIDENCE_LOG"

    if [[ "$_RALPH_AUTO_LAND" == "true" ]]; then
      echo "Auto-land: confidence=$_RALPH_CONFIDENCE, policy=$_RALPH_POLICY"
    else
      echo "Pausing for human review: confidence=$_RALPH_CONFIDENCE, policy=$_RALPH_POLICY"
      echo "  Press Enter to continue or Ctrl+C to abort..."
      read -r
    fi
  else
    echo "[$(date -Iseconds)] iter=$_RALPH_I bead=${_RALPH_BEAD_ID:-unknown} bead_type=$_RALPH_BEAD_TYPE bead_done=$_RALPH_BEAD_DONE confidence=NONE (no signal detected) gate_result=$_RALPH_GATE_RESULT${_RALPH_STALE_HEAD_FIELD} title=\"$(_ralph_sanitize_log_field "$_RALPH_BEAD_TITLE")\" completed=\"$(_ralph_sanitize_log_field "$_RALPH_COMPLETED_SUMMARY")\"" >> "$_RALPH_CONFIDENCE_LOG"
  fi

  # Footer: bead context + commit subject. Gated on _RALPH_COMPLETED_SUMMARY
  # non-empty so non-BEAD_DONE iters (BLOCKED / REWORK / no-signal) do not
  # print a duplicate "Resuming"-shape line — those branches already echoed
  # their own status above. On stale-HEAD iters the summary carries the
  # "(no new commit — stale HEAD)" marker so the audit reads correctly.
  if [[ -n "$_RALPH_COMPLETED_SUMMARY" ]]; then
    echo "  $_RALPH_BEAD_ID [$_RALPH_BEAD_TYPE] — $_RALPH_BEAD_TITLE"
    echo "  Completed: $_RALPH_COMPLETED_SUMMARY"
  fi
  echo "Iteration $_RALPH_I complete. Continuing..."
  sleep 2
done

if [[ -z "$RALPH_EXIT_CODE" ]]; then
  finish 1 "Ralph reached max iterations ($_RALPH_MAX_ITERATIONS) without completing all tasks. Check $_RALPH_ARCHIVE_FILE for status."
fi
