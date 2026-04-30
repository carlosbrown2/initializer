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

# Compute confidence from observable signals about the just-closed bead.
#
# Replaces the prior parse_confidence / parse_confidence_bead_done pair that
# extracted an agent-emitted `<confidence>` tag. Reads bash-observed gate
# result, commit diff size, whether risky paths were touched, and whether
# the loop is saturating on narrowing-shape follow-ups; returns a
# deterministic verdict the agent cannot spoof.
#
# Args:
#   gate_result      — "PASS" auto-lands; anything else returns LOW (fail-
#                      closed on unknown gate state).
#   diff_lines       — git show --numstat HEAD summed. Default 0.
#   touched_hooks    — "true" if HEAD touched scripts/hooks/.
#   touched_claude_md — "true" if HEAD touched CLAUDE.md outside
#                       `## Discovered Patterns`.
#   recent_followup_ratio — decimal in [0, 1]: fraction of last 5 closed
#                      beads with `Phase % follow-up:` titles. The
#                      AND-suppressor (no `Phase N impl:` or `integration-`
#                      close in the same window) is baked in by the caller
#                      (ralph.sh) by passing 0 when suppressed. Out-of-range
#                      values (e.g., a stale 5-arg call passing the legacy
#                      retry_count integer) are treated as no-signal and
#                      do not fire — pins the "ignore legacy 5-arg shape"
#                      invariant under bracket tests.
#
# Verdict: gate != "PASS" → LOW; else HIGH downgraded one level per axis:
# diff_lines>500, touched_hooks, touched_claude_md, ratio in [0,1] AND >0.6.
# 0 downgrades → HIGH; 1 → MEDIUM; 2+ → LOW.
#
# Net axis count preserved at 4 (cross-cutting invariant #3 in
# docs/upstream-harness-improvements.md). retry_count retired in this same
# change (fires on normal cadence after silent-fail iter, no correctness
# signal once gate=PASS); loop_saturation replaces it as the runtime
# detector for the runaway review feedback loop.
#
# Both thresholds (500 lines, 0.6 ratio) are heuristics calibrated against
# the template's own confidence.log distribution. Downstream projects
# recalibrate against their own iters; pair every threshold change with
# bracket-test updates pinning the new cut from both sides.
compute_confidence() {
  local gate_result="$1"
  local diff_lines="${2:-0}"
  local touched_hooks="${3:-false}"
  local touched_claude_md="${4:-false}"
  local recent_followup_ratio="${5:-0}"

  if [[ "$gate_result" != "PASS" ]]; then
    echo "LOW"
    return 0
  fi

  local downgrades=0
  [[ "$diff_lines" -gt 500 ]] && downgrades=$((downgrades + 1))
  [[ "$touched_hooks" == "true" ]] && downgrades=$((downgrades + 1))
  [[ "$touched_claude_md" == "true" ]] && downgrades=$((downgrades + 1))
  # loop_saturation: the ratio is a decimal in [0, 1]; out-of-range values
  # (e.g., a stale 5-arg call passing the legacy retry_count integer) are
  # treated as "no signal" and do not fire. awk handles the float comparison
  # bash cannot (bash's [[ ]] integer ops would mis-evaluate 0.8 vs 0.6).
  [[ "$(awk -v r="$recent_followup_ratio" 'BEGIN { print (r >= 0 && r <= 1 && r > 0.6) ? 1 : 0 }')" == "1" ]] && downgrades=$((downgrades + 1))

  case $downgrades in
    0) echo "HIGH" ;;
    1) echo "MEDIUM" ;;
    *) echo "LOW" ;;
  esac
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
# Unknown policy falls back to the documented default ("high"), which is
# safer than "all" for a template whose default propagates to every
# downstream project.
should_auto_land() {
  local confidence="$1"
  local policy="$2"
  case "$policy" in
    all)
      echo "true"
      ;;
    high)
      if [[ "$confidence" == "HIGH" ]]; then echo "true"; else echo "false"; fi
      ;;
    none)
      echo "false"
      ;;
    *)
      # Unknown policy: safer to pause than to auto-land. Documented
      # fallback matches the default policy, not the most-permissive one.
      if [[ "$confidence" == "HIGH" ]]; then echo "true"; else echo "false"; fi
      ;;
  esac
}

# Detect "BEAD_DONE without a new commit" by comparing the HEAD SHA captured
# at iter start against the HEAD SHA captured at BEAD_DONE detection.
#
# Per-iter measurements (diff_lines / touched_hooks / touched_claude_md in
# scripts/ralph/ralph.sh) read HEAD without verifying it has moved since
# iter start. If an iter emits BEAD_DONE without committing, the next
# measurement reads the *prior* commit's diff and credits that work to the
# current iter — cross-bead contamination compute_confidence cannot detect
# on its own. The fix is paired observation: one read at iter start, one
# at the decision point, refuse to grade if the state didn't move.
#
# Args:
#   pre_sha   — git rev-parse HEAD captured before the agent ran.
#   post_sha  — git rev-parse HEAD captured at BEAD_DONE detection.
#
# Returns:
#   0  HEAD unchanged (pre == post). Caller should force gate_result=FAIL.
#   1  HEAD moved (pre != post). Normal BEAD_DONE iter — caller proceeds.
#
# Intentionally narrow: it does not know *why* HEAD didn't move (agent
# forgot to commit, hook rejected the commit, agent stopped mid-iteration),
# only that it didn't. Routing the signal — forcing FAIL vs. ESCALATE vs.
# something else — is the caller's job in scripts/ralph/ralph.sh, where
# the rest of compute_confidence's inputs are in scope.
compute_head_unchanged_for_bead_done() {
  local pre_sha="$1"
  local post_sha="$2"
  if [[ "$pre_sha" == "$post_sha" ]]; then
    return 0
  fi
  return 1
}

# Detect whether CLAUDE.md was modified in HEAD outside its
# `## Discovered Patterns` section, by comparing HEAD~1:CLAUDE.md and
# HEAD:CLAUDE.md with the patterns block stripped from each side.
#
# `compute_confidence` downgrades when CLAUDE.md is touched because
# rule changes warrant scrutiny. But compound beads in this template's
# quartet pattern (impl → review → pare → compound) routinely promote
# model-tagged entries to `## Discovered Patterns` — an append-only
# output section that redefines no rule the gate runs. A naive
# "did CLAUDE.md change" check downgrades those edits anyway, so every
# compound bead saturates at MEDIUM regardless of the gate's verdict.
# This helper scopes the signal to the bug class actually worth pausing
# on: edits to `## Invariants`, `## Verification Gate`, `## Pinned Tool
# Versions`, and the prose between sections.
#
# Strategy: bypass unified-diff parsing entirely. Read both blob shapes,
# strip everything from `## Discovered Patterns` to the next top-level
# `## ` heading (or EOF) on each side, compare the rest. Hunk-header
# offsets and section reordering are handled trivially because the
# comparison is on stripped content, not on diff text.
#
# Args:
#   repo_root  — git repo root passed to `git -C`. Defaults to the
#                current working directory when omitted.
#
# Returns:
#   0  CLAUDE.md was modified outside `## Discovered Patterns` (or the
#      file was added or removed entirely between HEAD~1 and HEAD).
#      Caller should treat as `touched_claude_md=true`.
#   1  CLAUDE.md was unchanged, or the only changes were inside the
#      patterns section. Caller should treat as `touched_claude_md=false`.
#
# Style invariant: CLAUDE.md uses `## ` for top-level sections and `### `
# for entries inside `## Discovered Patterns`. If a downstream project
# ever uses `## ` for nested entries, the strip silently mis-bounds —
# pair an audit bead with that change.
claude_md_touched_outside_patterns() {
  local repo_root="${1:-.}"
  local cur_exists=true prev_exists=true
  git -C "$repo_root" cat-file -e HEAD:CLAUDE.md 2>/dev/null || cur_exists=false
  git -C "$repo_root" cat-file -e 'HEAD~1:CLAUDE.md' 2>/dev/null || prev_exists=false

  # File added or deleted (XOR): the file's existence flipped, which is
  # itself a non-trivial CLAUDE.md change regardless of section content.
  if [[ "$cur_exists" != "$prev_exists" ]]; then
    return 0
  fi

  # Neither side has the file (no parent commit and no current file, or
  # the project genuinely has no CLAUDE.md): nothing to grade.
  if [[ "$cur_exists" = "false" ]]; then
    return 1
  fi

  local cur prev
  cur=$(git -C "$repo_root" show HEAD:CLAUDE.md)
  prev=$(git -C "$repo_root" show 'HEAD~1:CLAUDE.md')

  local strip_awk='/^## Discovered Patterns[[:space:]]*$/{f=1;next} /^## /{f=0} !f'
  local cur_stripped prev_stripped
  cur_stripped=$(printf '%s' "$cur" | awk "$strip_awk")
  prev_stripped=$(printf '%s' "$prev" | awk "$strip_awk")

  if [[ "$cur_stripped" != "$prev_stripped" ]]; then
    return 0
  fi
  return 1
}

# Title regex for governance / audit beads — Observe / Audit / Decide /
# Triage / Review the loop. These name the operator's own meta-questions
# (audit instructions filed against the loop itself); when one sits in
# `bd ready` indefinitely the loop has been ignoring its own warning siren.
# Single source of truth so the surfacing helper in scripts/ralph/ralph.sh
# and the predicate below cannot drift on what counts as governance.
GOVERNANCE_TITLE_REGEX='^(Observe|Audit|Decide|Triage|Review the loop)'

# Shared jq fragment: convert a `bd` ISO-8601 timestamp string to a UTC
# epoch integer. bd emits offsets like `2026-04-30T07:19:57.075423-06:00`,
# but `fromdateiso8601` only accepts the `Z` (UTC) suffix — passing an
# offset-suffixed string crashes the filter. This def strips the
# fractional seconds, captures the `±HH:MM` offset, parses the naive
# stamp as UTC, then adjusts. Both governance_bead_max_age_days below and
# scripts/ralph/ralph.sh's _ralph_surface_stale_governance prepend this
# def to their jq programs so a future bd timestamp shape change lands
# in one place. Single-quoted: $m / $naive / $off are jq vars, not bash
# expansions — shellcheck SC2016 disabled because that's the design.
# shellcheck disable=SC2016
BD_DATE_TO_EPOCH_JQ_DEF='def bd_date_to_epoch: sub("\\.[0-9]+"; "") | if test("Z$") then fromdateiso8601 else capture("(?<dt>.+)(?<sign>[+-])(?<oh>[0-9]{2}):(?<om>[0-9]{2})$") as $m | (($m.dt + "Z") | fromdateiso8601) as $naive | (($m.oh | tonumber) * 3600 + ($m.om | tonumber) * 60) as $off | if $m.sign == "+" then $naive - $off else $naive + $off end end;'

# Predicate: returns 0 (truthy) if any governance bead in the input JSON
# has been open for more than 7 days; 1 otherwise. ralph.sh routes truthy
# by forcing the just-computed confidence to LOW for the iteration —
# HIGH on whatever just closed while a >1-week audit instruction is
# unanswered would be misleading regardless of the gate's verdict.
#
# Args:
#   json       — bd list --status=open --json output. Empty / malformed
#                input returns 1 (no governance bead found is benign).
#   now_epoch  — current time as Unix epoch seconds. Defaults to date +%s.
#                Tests pass a fixed value to keep the cut deterministic.
#
# Returns:
#   0  oldest governance bead age (in integer days) > 7
#   1  no matching bead, or oldest age ≤ 7
#
# The 7-day cut is the calibration parameter; ≤7d stays at the prevailing
# confidence, >7d forces LOW. Bracket tests at 7d (stays) and 8d (forces)
# pin the cut so a future `>` vs `>=` flip is caught mechanically. Integer
# days via floor: 7d23h reads as age=7 (≤7), 8d0h as age=8 (>7).
governance_bead_max_age_days() {
  local json="${1:-}"
  local now_epoch="${2:-$(date +%s)}"
  [[ -n "$json" ]] || return 1
  local oldest_epoch
  oldest_epoch=$(jq -r --arg re "$GOVERNANCE_TITLE_REGEX" "
    $BD_DATE_TO_EPOCH_JQ_DEF
    [.[]
      | select(.title | test(\$re))
      | (.created_at | bd_date_to_epoch)
    ] | if length == 0 then empty else min end
  " <<<"$json" 2>/dev/null) || return 1
  [[ -n "$oldest_epoch" ]] || return 1
  local age_days=$(( (now_epoch - oldest_epoch) / 86400 ))
  (( age_days > 7 )) && return 0
  return 1
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
