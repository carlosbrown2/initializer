#!/bin/bash
# scripts/ralph/lib.sh — pure routing functions for scripts/ralph/ralph.sh
#
# Extracted into a sourceable library so the regex anchors, policy matrix,
# retry-state transitions, and prereq-id extractor can be exercised by
# tests/hooks/ralph.bats without running the main agent loop. ralph.sh
# sources this at runtime; the bats suite sources it at test time. The
# "one implementation, one library" pattern (CLAUDE.md § Discovered
# Patterns) — production and tests both load these definitions from a
# single file, so drift between callers is not possible.

# --- Bead id regex -------------------------------------------------------
# Single source of truth for what a bead id looks like. Used by
# extract_prereq_bead_id and by scripts/hooks/parsers.sh. Previously the
# two call sites had drifted regexes (one allowed [a-z_], the other [a-z]),
# which is exactly the bug class the decision register names.
BEAD_ID_REGEX='[a-z][-a-z0-9]*-[a-z0-9]{2,}'

# Extract the iteration exit signal from agent output.
#
# The loop used to route by grepping the entire transcript independently
# for each promise tag, with COMPLETE checked first. That made any stray
# mention of `<promise>COMPLETE</promise>` in an otherwise successful
# BEAD_DONE transcript terminate the whole Ralph loop after one bead. Bind
# routing to the first standalone promise line instead: the prompt contract
# requires the agent to emit exactly one exit signal, and explanatory prose
# that happens to quote another signal should not outrank the actual signal.
extract_promise_signal() {
  sed -nE 's/^[[:space:]]*<promise>(BEAD_DONE|BLOCKED|REWORK_REQUIRED|COMPLETE)<\/promise>[[:space:]]*$/\1/p' | head -1
}

# Return whether the tracker still has unfinished work.
#
# `bd ready` is not a complete definition of "Ralph should exit": it only
# answers "is there an unblocked bead right now?" The loop's termination
# condition is stricter: no open beads and no in-progress beads. If the
# agent emits COMPLETE while either status still exists, the loop must keep
# running (or fail loudly if tracker state cannot be verified) rather than
# silently stopping with work stranded in the tracker.
#
# Return codes:
#   0 — unfinished beads exist (open and/or in_progress)
#   1 — no unfinished beads remain
#   2 — tracker state could not be verified (bd/jq failure)
tracker_has_unfinished_beads() {
  local out open_count in_progress_count

  out=$(bd list --status=open --json 2>/dev/null) || return 2
  open_count=$(jq -r 'if type == "array" then length else 0 end' <<<"$out" 2>/dev/null) || return 2

  out=$(bd list --status=in_progress --json 2>/dev/null) || return 2
  in_progress_count=$(jq -r 'if type == "array" then length else 0 end' <<<"$out" 2>/dev/null) || return 2

  if (( open_count > 0 || in_progress_count > 0 )); then
    return 0
  fi
  return 1
}

# Return 0 when the repo worktree is clean, non-zero otherwise.
#
# Uses `git status --porcelain` so tracked edits, staged changes, and
# untracked files all count as dirty. Gitignored runtime files such as
# `.last-gate-result` are already excluded by git itself, so the check
# stays focused on landable repo state rather than ephemeral loop output.
git_worktree_clean() {
  local repo_root="$1"
  local status_out
  status_out=$(git -C "$repo_root" status --porcelain 2>/dev/null) || return 1
  [ -z "$status_out" ]
}

# Run the post-BEAD_DONE landing ritual.
#
# The agent is responsible for the bead's implementation commit before it
# emits BEAD_DONE. Ralph owns the session-ending landing steps after that:
#   1. require a clean worktree
#   2. `git pull --rebase`
#   3. `bd sync`
#   4. commit the resulting beads-state update if and only if bd sync dirtied
#      `.beads/issues.jsonl`
#   5. `git push`
#   6. verify upstream parity and a clean post-push worktree
#
# On success, prints `LANDED` and returns 0. On failure, prints a stable
# machine-readable reason token and returns non-zero so ralph.sh can log and
# stop rather than silently continuing past a stranded bead.
auto_land_bead() {
  local repo_root="$1"
  local bead_id="$2"
  local status_out path line upstream_ref head_ref upstream_head

  if ! git_worktree_clean "$repo_root"; then
    printf 'DIRTY_WORKTREE_BEFORE_LAND\n'
    return 1
  fi

  if ! git -C "$repo_root" pull --rebase; then
    printf 'PULL_REBASE_FAILED\n'
    return 1
  fi

  if ! bd sync; then
    printf 'BD_SYNC_FAILED\n'
    return 1
  fi

  status_out=$(git -C "$repo_root" status --porcelain 2>/dev/null) || {
    printf 'STATUS_CHECK_FAILED_AFTER_BD_SYNC\n'
    return 1
  }

  if [ -n "$status_out" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      path="${line#?? }"
      if [ "$path" != ".beads/issues.jsonl" ]; then
        printf 'UNEXPECTED_BD_SYNC_DIFF\n'
        return 1
      fi
    done <<<"$status_out"

    if ! git -C "$repo_root" add .beads/issues.jsonl; then
      printf 'SYNC_ADD_FAILED\n'
      return 1
    fi
    if ! git -C "$repo_root" commit -m "chore: bd sync - close $bead_id"; then
      printf 'SYNC_COMMIT_FAILED\n'
      return 1
    fi
  fi

  if ! git -C "$repo_root" push; then
    printf 'PUSH_FAILED\n'
    return 1
  fi

  if ! git_worktree_clean "$repo_root"; then
    printf 'DIRTY_WORKTREE_AFTER_PUSH\n'
    return 1
  fi

  upstream_ref=$(git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || {
    printf 'NO_UPSTREAM_TRACKING_BRANCH\n'
    return 1
  }
  head_ref=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null) || {
    printf 'HEAD_RESOLUTION_FAILED\n'
    return 1
  }
  upstream_head=$(git -C "$repo_root" rev-parse "$upstream_ref" 2>/dev/null) || {
    printf 'UPSTREAM_RESOLUTION_FAILED\n'
    return 1
  }

  if [ "$head_ref" != "$upstream_head" ]; then
    printf 'UPSTREAM_MISMATCH_AFTER_PUSH\n'
    return 1
  fi

  printf 'LANDED\n'
}

# Execute the verification gate command and record the real exit code.
#
# Replaces the prior design where the agent ran the gate and self-reported
# via `<gate-result>PASS|FAIL</gate-result>`. The self-report was a proxy:
# an agent could skip, misquote, or hallucinate the run and leave a green
# tag next to red code. Binding `.last-gate-result` to the *observed* exit
# code of `bash -c "$gate_cmd"` replaces a prediction with a measurement.
#
# The pre-push hook (scripts/hooks/install.sh) stays in place as defense
# in depth — it re-runs the same gate on push and blocks on divergence
# against the file this function writes. The two callers reach identical
# verdicts against an honest gate; a divergence now means the gate itself
# changed between iteration and push (env drift, untracked file moved,
# tool version changed), not that the agent lied.
#
# Args:
#   gate_cmd     — the verification gate command string (from CLAUDE.md
#                  via scripts/hooks/parsers.sh gate_command_extract).
#   result_file  — absolute path to .last-gate-result; overwritten with
#                  PASS, FAIL, or SKIPPED.
# Returns:
#   0 on PASS; non-zero on FAIL or empty gate_cmd (SKIPPED). Callers that
#   want to route on the outcome can read the file or check the exit code.
run_gate() {
  local gate_cmd="$1"
  local result_file="$2"
  if [ -z "$gate_cmd" ]; then
    printf 'SKIPPED\n' > "$result_file"
    return 1
  fi
  if bash -c "$gate_cmd"; then
    printf 'PASS\n' > "$result_file"
    return 0
  else
    printf 'FAIL\n' > "$result_file"
    return 1
  fi
}

# Compute confidence from the observed gate result.
#
# Single-axis: gate=PASS → HIGH; anything else → LOW. The prior 4-axis stack
# (diff size, touched_hooks, touched_claude_md with carve-out) was a
# hand-calibrated heuristic stacked on top of the gate's verdict; collapsing
# to gate-only lets the gate be the single source of truth a future model
# can reason about, and removes a class of "MEDIUM saturated against a
# clean gate" misroutes the carve-out chased.
#
# Trailing positional args are silently ignored by bash, so legacy callers
# passing diff_lines / touched_hooks / touched_claude_md (or older
# retry_count / recent_followup_ratio) collapse to no-signal — the only
# input that routes is gate_result.
compute_confidence() {
  local gate_result="$1"
  if [[ "$gate_result" == "PASS" ]]; then
    echo "HIGH"
  else
    echo "LOW"
  fi
}

# Read auto-land policy from CLAUDE.md ## Confidence Routing section.
# Uses awk to walk the section (heading to next `## `) so blank lines
# between heading and value do not drop the match, and commented-out
# `# auto-land: ...` lines are ignored (the line must start with
# optional whitespace then `auto-land:`).
#
# Default policy is "high" (safer-by-default for a template that every
# downstream project inherits). A project that trusts its gate can opt
# into "all" by writing `auto-land: all` in its own CLAUDE.md. This
# default matches the shipped starter CLAUDE.md in the template repo.
read_auto_land_policy() {
  local claude_md="$1"
  if [[ -f "$claude_md" ]]; then
    local policy
    policy=$(awk '
      /^## Confidence Routing[[:space:]]*$/ { in_sec=1; next }
      in_sec && /^## / { exit }
      in_sec && /^[[:space:]]*auto-land:/ {
        sub(/^[[:space:]]*auto-land:[[:space:]]*/, "")
        sub(/[[:space:]]*$/, "")
        print
        exit
      }
    ' "$claude_md")
    echo "${policy:-high}"
  else
    echo "high"
  fi
}

# Determine if auto-land is allowed for given confidence + policy.
# compute_confidence is binary HIGH/LOW (the MEDIUM tier was retired with
# the 4-axis collapse), so the policy matrix only sees those two values
# in practice — `none` always pauses, `all` always lands, and `high` /
# unknown collapse to "land iff HIGH". Unknown policy falls back to the
# documented default ("high"), which is safer than "all" for a template
# whose default propagates to every downstream project.
should_auto_land() {
  local confidence="$1"
  local policy="$2"
  case "$policy" in
    all)
      echo "true"
      ;;
    none)
      echo "false"
      ;;
    *)
      # `high` and any unknown policy: safer to pause than to auto-land.
      if [[ "$confidence" == "HIGH" ]]; then echo "true"; else echo "false"; fi
      ;;
  esac
}

# Pure retry-state transition. Given the just-failed bead id, the prior
# last-failed bead id, the current fail count, and max retries, print the
# new tuple "NEW_COUNT|NEW_LAST|ACTION" to stdout. Action is one of:
#   noop     — no bead was in progress to attribute the failure to
#   continue — increment or start; caller continues the loop
#   escalate — fail count reached max; caller should unclaim + file blocker
compute_retry_state() {
  local failed_bead="$1"
  local last_failed_bead="$2"
  local fail_count="$3"
  local max_retries="$4"
  local new_count new_last action

  if [[ -z "$failed_bead" ]]; then
    printf '%s|%s|noop\n' "$fail_count" "$last_failed_bead"
    return 0
  fi

  if [[ "$failed_bead" == "$last_failed_bead" ]]; then
    new_count=$((fail_count + 1))
    new_last="$last_failed_bead"
  else
    new_count=1
    new_last="$failed_bead"
  fi

  if [[ $new_count -ge $max_retries ]]; then
    action="escalate"
  else
    action="continue"
  fi

  printf '%s|%s|%s\n' "$new_count" "$new_last" "$action"
}

# Extract the prerequisite bead id from `bd dep list <active_bead>` output
# read from stdin. The dep list output begins with a header line of the
# form "<active_bead> depends on:" whose bead-id token matches the prereq
# regex, so a naive `head -1` would return the active bead itself (a no-op
# update instead of re-opening the real prerequisite). Excluding the
# active bead id before `head -1` binds the extraction to the property we
# actually want — the first *prerequisite* id, not the first id-shaped
# token in the text.
#
# Uses BEAD_ID_REGEX as the single source of truth for id shape so this
# extractor and the pre-commit hook's extractor cannot disagree.
extract_prereq_bead_id() {
  local active_bead="$1"
  grep -oE "$BEAD_ID_REGEX" | grep -Fvx -- "$active_bead" | head -1
}
