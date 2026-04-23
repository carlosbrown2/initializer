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

# Extract confidence level from agent output.
#
# Patterns require the closing `>` so the placeholder string
# `<confidence level="{ONE_OF_HIGH_MEDIUM_LOW}">` in prompt.md does not
# collide with a real emission and leak into the routing decision.
#
# HIGH precedence is documented in tests/hooks/ralph.bats. Note this is
# the legacy extractor — it fires for any confidence tag anywhere in the
# output. ralph.sh uses parse_confidence_bead_done (below) on the BEAD_DONE
# path to prevent rationale text from spoofing the signal.
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

# Extract the confidence level that IMMEDIATELY precedes <promise>BEAD_DONE</promise>.
#
# prompt.md's contract is "Emit immediately before <promise>BEAD_DONE</promise>".
# Binding the extractor to that contract prevents rationale text like
# "earlier I emitted <confidence level=\"LOW\"> but it should have been HIGH"
# from spoofing the routing decision — only the final tag counts.
#
# Whitespace (including newlines) between the closing </confidence> and
# the opening <promise>BEAD_DONE</promise> is tolerated. If no confidence
# tag immediately precedes BEAD_DONE, returns empty (so the caller treats
# it as "no signal" and logs accordingly, rather than silently using the
# wrong level).
parse_confidence_bead_done() {
  local output="$1"
  # Accumulate all input into a buffer and match in END. BWK awk (macOS
  # default) silently ignores RS="\0" and falls back to per-line processing,
  # which loses any match whose whitespace between </confidence> and
  # <promise> spans a newline. Buffer-and-match-in-END is portable across
  # gawk and BWK.
  echo "$output" | awk '
    { buf = buf $0 "\n" }
    END {
      # Capture level of the <confidence level="X"> that is followed only
      # by whitespace and then <promise>BEAD_DONE</promise>. Because the
      # pattern requires whitespace-only between the closing tag and the
      # promise, the only tag that can match is the one immediately before.
      if (match(buf, /<confidence level="(HIGH|MEDIUM|LOW)">[^<]*<\/confidence>[[:space:]]*<promise>BEAD_DONE<\/promise>/)) {
        segment = substr(buf, RSTART, RLENGTH)
        if (match(segment, /<confidence level="(HIGH|MEDIUM|LOW)">/)) {
          tag = substr(segment, RSTART, RLENGTH)
          # Pull the level out of the tag.
          sub(/<confidence level="/, "", tag)
          sub(/">/, "", tag)
          print tag
        }
      }
    }
  '
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
