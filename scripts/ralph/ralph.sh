#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: source ralph.sh [--tool claude|codex|amp] [max_iterations]
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
  unset _RALPH_PROMPT_FILE _RALPH_ARCHIVE_FILE
  unset _RALPH_CONFIDENCE_LOG _RALPH_RETRY_STATE_FILE _RALPH_LIB
  unset _RALPH_PARSERS _RALPH_GATE_CMD
  unset _RALPH_FAIL_COUNT _RALPH_LAST_FAILED_BEAD _RALPH_MAX_RETRIES
  unset _RALPH_I _RALPH_CURRENT_BEAD _RALPH_ACTIVE_BEAD
  unset _RALPH_BEAD_ID _RALPH_BEAD_TITLE _RALPH_OUTPUT
  unset _RALPH_PROMISE_SIGNAL
  unset _RALPH_TRACKER_STATE
  unset _RALPH_COMPLETE_ACTION _RALPH_COMPLETE_FINISH_CODE _RALPH_COMPLETE_FINISH_MESSAGE
  unset _RALPH_SIGNAL_ACTION _RALPH_SIGNAL_FINISH_CODE _RALPH_SIGNAL_FINISH_MESSAGE
  unset _RALPH_BEAD_TYPE _RALPH_BEAD_DESCRIPTION _RALPH_COMPLETED_SUMMARY
  unset _RALPH_BEAD_DONE _RALPH_BLOCKED_REASON _RALPH_REWORK_REASON
  unset _RALPH_PREREQ_BEAD _RALPH_BLOCKER_TITLE
  unset _RALPH_GATE_RESULT _RALPH_CONFIDENCE _RALPH_POLICY _RALPH_AUTO_LAND
  unset _RALPH_LANDING_STATUS _RALPH_LANDING_REASON
  unset _RALPH_POST_BEAD_ACTION _RALPH_POST_BEAD_FINISH_CODE _RALPH_POST_BEAD_FINISH_MESSAGE
  unset _RALPH_FAILED_BEAD _RALPH_RETRY_STATE _RALPH_RETRY_REST _RALPH_RETRY_ACTION
  unset -f _ralph_cleanup _ralph_bead_in_progress _ralph_bead_ready _ralph_bead_title
  unset -f _ralph_load_bead_meta _ralph_sanitize_log_field _ralph_work_summary
  unset -f _ralph_acceptance_summary _ralph_emit_log
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
# when no impl/review/pare/compound/research keyword matches. The keyword
# loop (vs single regex+BASH_REMATCH[2]) is for zsh-source compat: zsh
# does not populate BASH_REMATCH by default, so capture-group extraction
# would crash under `set -u` when the script is sourced from a zsh shell.
_ralph_load_bead_meta() {
  local id="$1" j issue_type acceptance_criteria _kw
  _RALPH_BEAD_TYPE=""; _RALPH_BEAD_TITLE=""; _RALPH_BEAD_DESCRIPTION=""
  j=$(bd show "$id" --json 2>/dev/null) || return 0
  [ -n "$j" ] || return 0
  _RALPH_BEAD_TITLE=$(jq -r '(if type == "array" then .[0] else . end).title // empty' <<<"$j" 2>/dev/null) || _RALPH_BEAD_TITLE=""
  _RALPH_BEAD_DESCRIPTION=$(jq -r '(if type == "array" then .[0] else . end).description // empty' <<<"$j" 2>/dev/null) || _RALPH_BEAD_DESCRIPTION=""
  acceptance_criteria=$(jq -r '(if type == "array" then .[0] else . end).acceptance_criteria // empty' <<<"$j" 2>/dev/null) || acceptance_criteria=""
  if [[ -n "$acceptance_criteria" ]] && ! grep -qi 'acceptance criteria' <<<"$_RALPH_BEAD_DESCRIPTION"; then
    _RALPH_BEAD_DESCRIPTION+=$'\n\nACCEPTANCE CRITERIA\n'
    _RALPH_BEAD_DESCRIPTION+="$acceptance_criteria"
  fi
  issue_type=$(jq -r '(if type == "array" then .[0] else . end).issue_type // empty' <<<"$j" 2>/dev/null) || issue_type=""
  _RALPH_BEAD_TYPE="$issue_type"
  for _kw in pare-down impl review pare compound research; do
    if [[ "$_RALPH_BEAD_TITLE" =~ (^|[[:space:]])${_kw}[[:space:]]*: ]]; then _RALPH_BEAD_TYPE="$_kw"; break; fi
  done
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

_ralph_work_summary() {
  local s="$1"
  s=$(awk '
    {
      line = tolower($0)
      if (line ~ /^[[:space:]]*acceptance[[:space:]]+criteria/) {
        exit
      }
      print
    }
  ' <<<"$s" | tr '[:space:]' ' ' | tr -s ' ')
  s="${s# }"
  s="${s% }"
  if [ -z "$s" ]; then
    s="No summary provided."
  elif [ "${#s}" -gt 160 ]; then
    s="${s:0:157}..."
  fi
  printf '%s' "$s"
}

_ralph_acceptance_summary() {
  local s="$1"
  awk '
    {
      line = tolower($0)
      if (!in_acceptance && line ~ /^[[:space:]]*acceptance[[:space:]]+criteria/) {
        in_acceptance = 1
        next
      }
      if (in_acceptance && $0 ~ /^[[:space:]]*[-*][[:space:]]+/) {
        item = $0
        sub(/^[[:space:]]*[-*][[:space:]]+/, "", item)
        gsub(/[[:space:]]+/, " ", item)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
        if (item != "") {
          count++
          if (first == "") {
            first = item
          }
        }
      }
    }
    END {
      if (count == 0) {
        print "No explicit criteria found."
        exit
      }
      if (length(first) > 90) {
        first = substr(first, 1, 87) "..."
      }
      printf "%d criteria; first: %s", count, first
      if (count > 1) {
        printf "; %d more", count - 1
      }
      print ""
    }
  ' <<<"$s"
}

# Emit one confidence.log line. The five exit-routing branches (BLOCKED,
# REWORK, ESCALATION, BEAD_DONE-with-confidence, BEAD_DONE-without-
# confidence) all share the same prefix (`[ts] iter=N [STATUS] bead=ID
# bead_type=T`) and the same suffix (`title="<sanitized>" [completed=...]`)
# but differ on the middle field set; collapsing here keeps the prefix /
# suffix shape (and the `_ralph_sanitize_log_field` application) defined
# once. Backward-compat invariants pinned by tests/hooks/ralph.bats:
# (a) `bead=<id-or-unknown>` survives `grep -oE 'bead=[^ ]+'` extraction
# in archive_schema_check; (b) title/completed are sanitized.
_ralph_emit_log() {
  # `emit_status`, not `status`: zsh reserves `status` as a read-only special
  # parameter (alias of `$?`), so `local status=...` aborts under a sourced
  # zsh shell with `read-only variable: status`. The script is sourced from
  # the user's interactive shell, so any function-local that collides with a
  # zsh special name unwinds the loop before `_ralph_cleanup` can restore
  # `set +u` — the symptom is the user's prompt then erroring on every
  # unset prompt-segment variable (RPROMPT / VIRTUAL_ENV / etc.).
  local emit_status="$1"
  local bead="${2:-unknown}"
  local middle="$3"
  local include_completed="${4:-no}"
  local line
  line="[$(date -Iseconds)] iter=$_RALPH_I"
  [[ -n "$emit_status" ]] && line+=" $emit_status"
  line+=" bead=$bead bead_type=$_RALPH_BEAD_TYPE"
  [[ -n "$middle" ]] && line+=" $middle"
  line+=" title=\"$(_ralph_sanitize_log_field "$_RALPH_BEAD_TITLE")\""
  if [[ "$include_completed" == "yes" ]]; then
    line+=" completed=\"$(_ralph_sanitize_log_field "${_RALPH_COMPLETED_SUMMARY:-}")\""
  fi
  echo "$line" >> "$_RALPH_CONFIDENCE_LOG"
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
_RALPH_TOOL="codex"
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

if [[ "$_RALPH_TOOL" != "amp" && "$_RALPH_TOOL" != "claude" && "$_RALPH_TOOL" != "codex" ]]; then
  echo "Error: Invalid tool '$_RALPH_TOOL'. Must be 'claude', 'codex', or 'amp'."
  _ralph_cleanup
  return 1
fi

_RALPH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_RALPH_PROJECT_ROOT="$(cd "$_RALPH_SCRIPT_DIR/../.." && pwd)"
_RALPH_PROMPT_FILE="$_RALPH_SCRIPT_DIR/prompt.md"
_RALPH_ARCHIVE_FILE="$_RALPH_SCRIPT_DIR/archive.txt"
_RALPH_CONFIDENCE_LOG="$_RALPH_SCRIPT_DIR/confidence.log"
_RALPH_RETRY_STATE_FILE="$_RALPH_SCRIPT_DIR/retry_state.json"

# Source routing functions (promise extraction, tracker verification,
# retry transitions, gate/confidence/landing routing, and auto-land helpers)
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

if ! ensure_git_index_writable "$_RALPH_PROJECT_ROOT"; then
  echo "Error: git index is not writable after repair attempts."
  echo "  Ralph needs a writable .git/index.lock to make progress."
  _ralph_cleanup
  return 1
fi

# Retry tracking
_RALPH_FAIL_COUNT=0
_RALPH_LAST_FAILED_BEAD=""
_RALPH_MAX_RETRIES=3

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

  if [[ -z "$_RALPH_ACTIVE_BEAD" ]] && ! git_worktree_clean "$_RALPH_PROJECT_ROOT"; then
    echo "Error: worktree is dirty but no bead is in progress."
    echo "  Ralph will not start a new bead over mixed local changes."
    echo "  Commit, restore, or preserve the existing diff before continuing."
    git_worktree_status "$_RALPH_PROJECT_ROOT"
    _ralph_cleanup
    return 1
  fi

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
    echo "Work: $(_ralph_work_summary "$_RALPH_BEAD_DESCRIPTION")"
    echo "Acceptance: $(_ralph_acceptance_summary "$_RALPH_BEAD_DESCRIPTION")"
  else
    echo "No beads ready — agent will check and emit COMPLETE."
  fi
  echo "---------------------------------------------------------------"

  # Run the selected tool with the ralph prompt
  if [[ "$_RALPH_TOOL" == "amp" ]]; then
    _RALPH_OUTPUT=$(amp --dangerously-allow-all < "$_RALPH_PROMPT_FILE" 2>&1 | tee /dev/stderr) || true
  elif [[ "$_RALPH_TOOL" == "codex" ]]; then
    # Codex CLI: exec mode for non-interactive operation, rooted at the repo.
    _RALPH_OUTPUT=$(codex --ask-for-approval never --sandbox workspace-write --cd "$_RALPH_PROJECT_ROOT" exec - < "$_RALPH_PROMPT_FILE" 2>&1 | tee /dev/stderr) || true
  else
    # Claude Code: --dangerously-skip-permissions for autonomous operation, --print for output
    _RALPH_OUTPUT=$(claude --dangerously-skip-permissions --print < "$_RALPH_PROMPT_FILE" 2>&1 | tee /dev/stderr) || true
  fi

  _RALPH_PROMISE_SIGNAL=$(extract_promise_signal <<<"$_RALPH_OUTPUT")

  # Check for completion signal (all work done)
  handle_complete_promise
  if [[ "$_RALPH_COMPLETE_ACTION" == "finish" ]]; then
    finish "$_RALPH_COMPLETE_FINISH_CODE" "$_RALPH_COMPLETE_FINISH_MESSAGE"
    break
  fi

  # Check for rate limit signal
  if echo "$_RALPH_OUTPUT" | grep -qi "You've hit your limit\|you have hit your limit\|rate limit\|usage limit"; then
    finish 2 "Ralph hit agent rate limit at iteration $_RALPH_I. Exiting gracefully."
    break
  fi

  # --- Exit signal routing ---
  handle_iteration_signal
  if [[ "$_RALPH_SIGNAL_ACTION" == "finish" ]]; then
    finish "$_RALPH_SIGNAL_FINISH_CODE" "$_RALPH_SIGNAL_FINISH_MESSAGE"
    break
  fi

  # --- Gate result + confidence routing (bash-run, not agent self-report) ---
  # handle_post_bead_done_routing owns the gate re-run, confidence verdict,
  # landing attempt, and outcome logging. The top-level loop only reacts to
  # its explicit finish/continue action.
  handle_post_bead_done_routing
  if [[ "$_RALPH_POST_BEAD_ACTION" == "finish" ]]; then
    finish "$_RALPH_POST_BEAD_FINISH_CODE" "$_RALPH_POST_BEAD_FINISH_MESSAGE"
    break
  fi

  # Footer: bead context + commit subject. Gated on _RALPH_COMPLETED_SUMMARY
  # non-empty so non-BEAD_DONE iters (BLOCKED / REWORK / no-signal) do not
  # print a duplicate "Resuming"-shape line — those branches already echoed
  # their own status above.
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
