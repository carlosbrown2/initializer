#!/usr/bin/env bats
# tests/hooks/ralph.bats — bats suite for scripts/ralph/lib.sh
#
# ralph.sh sources lib.sh; the gate only parse-checks ralph.sh, which does
# not dereference the source at parse time, so a syntax error or logic
# regression in lib.sh would otherwise surface only in a live agent run.
# This suite exercises each routing function against the edge cases the
# bead (agent-template-0iy) calls out explicitly, plus adversarial cases
# that exploit the shape of the current checks:
#   - parse_confidence against the prompt.md placeholder
#   - read_auto_land_policy across section-parse edge cases (blank line
#     between heading and value, commented-out alternatives, section
#     bounded by next ##)
#   - should_auto_land matrix including unknown policy
#   - compute_retry_state increment / reset / escalation boundaries
#   - extract_prereq_bead_id excluding the active-bead header line
#     (naive head -1 would return the active bead itself — a no-op update
#     instead of re-opening the real prerequisite)

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/ralph/lib.sh"
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# --- tool selection ------------------------------------------------------

@test "ralph.sh advertises claude, codex, and amp as supported tools" {
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  grep -qF 'Usage: source ralph.sh [--tool claude|codex|amp]' "$ralph"
  grep -qF "Must be 'claude', 'codex', or 'amp'." "$ralph"
}

@test "ralph.sh defaults to codex" {
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  grep -qF '_RALPH_TOOL="codex"' "$ralph"
}

@test "ralph.sh codex branch uses non-interactive exec rooted at the repo" {
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  grep -qF '[[ "$_RALPH_TOOL" == "codex" ]]' "$ralph"
  grep -qF 'codex --ask-for-approval never --sandbox workspace-write --cd "$_RALPH_PROJECT_ROOT" exec - < "$_RALPH_PROMPT_FILE"' "$ralph"
}

# --- extract_promise_signal ---------------------------------------------

@test "extract_promise_signal: BEAD_DONE wins over stray COMPLETE prose" {
  # Regression: ralph.sh used to grep the whole transcript for COMPLETE
  # before BEAD_DONE, so a successful iteration that mentioned COMPLETE in
  # explanatory text stopped the outer loop after one bead.
  output=$'work completed\n<promise>BEAD_DONE</promise>\nDo not emit <promise>COMPLETE</promise> until bd ready is empty.'
  run bash -c 'source "$0"; extract_promise_signal <<<"$1"' "$PROJECT_ROOT/scripts/ralph/lib.sh" "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "BEAD_DONE" ]
}

@test "extract_promise_signal: returns COMPLETE from standalone signal line" {
  output=$'No beads ready.\n<promise>COMPLETE</promise>'
  run bash -c 'source "$0"; extract_promise_signal <<<"$1"' "$PROJECT_ROOT/scripts/ralph/lib.sh" "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "COMPLETE" ]
}

@test "extract_promise_signal: ignores inline quoted promise tags" {
  output='The available signals include <promise>COMPLETE</promise>.'
  run bash -c 'source "$0"; extract_promise_signal <<<"$1"' "$PROJECT_ROOT/scripts/ralph/lib.sh" "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- tracker_has_unfinished_beads ---------------------------------------

@test "tracker_has_unfinished_beads: returns 0 when open beads exist" {
  mkdir -p "$TMPDIR_TEST/bin"
  cat > "$TMPDIR_TEST/bin/bd" <<'EOF'
#!/bin/bash
if [[ "$1 $2" == "list --status=open" ]]; then
  printf '%s\n' '[{"id":"agent-template-open"}]'
elif [[ "$1 $2" == "list --status=in_progress" ]]; then
  printf '%s\n' '[]'
else
  exit 1
fi
EOF
  chmod +x "$TMPDIR_TEST/bin/bd"
  PATH="$TMPDIR_TEST/bin:$PATH"

  run tracker_has_unfinished_beads
  [ "$status" -eq 0 ]
}

@test "tracker_has_unfinished_beads: returns 0 when an in-progress bead exists" {
  mkdir -p "$TMPDIR_TEST/bin"
  cat > "$TMPDIR_TEST/bin/bd" <<'EOF'
#!/bin/bash
if [[ "$1 $2" == "list --status=open" ]]; then
  printf '%s\n' '[]'
elif [[ "$1 $2" == "list --status=in_progress" ]]; then
  printf '%s\n' '[{"id":"agent-template-live"}]'
else
  exit 1
fi
EOF
  chmod +x "$TMPDIR_TEST/bin/bd"
  PATH="$TMPDIR_TEST/bin:$PATH"

  run tracker_has_unfinished_beads
  [ "$status" -eq 0 ]
}

@test "tracker_has_unfinished_beads: returns 1 when open and in-progress lists are empty" {
  mkdir -p "$TMPDIR_TEST/bin"
  cat > "$TMPDIR_TEST/bin/bd" <<'EOF'
#!/bin/bash
if [[ "$1" == "list" ]]; then
  printf '%s\n' '[]'
else
  exit 1
fi
EOF
  chmod +x "$TMPDIR_TEST/bin/bd"
  PATH="$TMPDIR_TEST/bin:$PATH"

  run tracker_has_unfinished_beads
  [ "$status" -eq 1 ]
}

@test "tracker_has_unfinished_beads: returns 2 on bd failure" {
  mkdir -p "$TMPDIR_TEST/bin"
  cat > "$TMPDIR_TEST/bin/bd" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$TMPDIR_TEST/bin/bd"
  PATH="$TMPDIR_TEST/bin:$PATH"

  run tracker_has_unfinished_beads
  [ "$status" -eq 2 ]
}

@test "tracker_has_unfinished_beads: returns 2 on non-parseable JSON" {
  mkdir -p "$TMPDIR_TEST/bin"
  cat > "$TMPDIR_TEST/bin/bd" <<'EOF'
#!/bin/bash
printf '%s\n' 'not-json'
EOF
  chmod +x "$TMPDIR_TEST/bin/bd"
  PATH="$TMPDIR_TEST/bin:$PATH"

  run tracker_has_unfinished_beads
  [ "$status" -eq 2 ]
}

# --- compute_confidence --------------------------------------------------
#
# Single-axis routing: gate=PASS → HIGH, anything else → LOW. The prior
# 4-axis stack (diff size, touched_hooks, touched_claude_md) was a hand-
# calibrated heuristic stacked on top of the gate verdict; the collapse
# lets the gate be the single routing input.

@test "compute_confidence: gate FAIL returns LOW" {
  # A red gate forbids auto-land. Pins the fail-closed property.
  run compute_confidence "FAIL"
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

@test "compute_confidence: gate SKIPPED is treated as non-PASS (LOW)" {
  # Three-valued .last-gate-result (PASS/FAIL/SKIPPED). SKIPPED means the
  # gate extractor returned empty — unknown gate state. Fail closed to LOW
  # rather than letting an unknown state auto-land.
  run compute_confidence "SKIPPED"
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

@test "compute_confidence: empty gate result is treated as non-PASS (LOW)" {
  # Defensive: if the caller forgets to pass gate_result, fall through to
  # LOW. Preserves the "fail closed on unknown gate" property even against
  # a programmer error at the call site.
  run compute_confidence ""
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

@test "compute_confidence: gate PASS returns HIGH" {
  # The only auto-land configuration under 'auto-land: high' (the shipped
  # default for the template).
  run compute_confidence "PASS"
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "compute_confidence: trailing positional args are silently ignored" {
  # Legacy call sites passed diff_lines / touched_hooks / touched_claude_md
  # (and earlier retry_count / recent_followup_ratio). bash drops trailing
  # args past the declared positionals, so a stale caller still routes on
  # gate_result alone — pins the "ignore legacy N-arg shape" invariant.
  run compute_confidence "PASS" 1000 "true" "true" 5
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "compute_confidence: trailing args do not flip a FAIL into HIGH" {
  # Complement to the above: legacy diff/touched args cannot rescue a red
  # gate. The single routing input is gate_result.
  run compute_confidence "FAIL" 0 "false" "false"
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

# --- read_auto_land_policy ----------------------------------------------

@test "read_auto_land_policy: returns 'high' (new safer default) when file is missing" {
  # Default flipped from 'all' to 'high' so a template whose shipped
  # CLAUDE.md is missing or unreadable pauses on non-HIGH rather than
  # silently auto-landing everything.
  run read_auto_land_policy "$TMPDIR_TEST/does-not-exist.md"
  [ "$status" -eq 0 ]
  [ "$output" = "high" ]
}

@test "read_auto_land_policy: returns 'high' when section has no auto-land line" {
  cat > "$TMPDIR_TEST/CLAUDE.md" <<'EOF'
# Proj

## Confidence Routing

prose here, no setting

## Other
EOF
  run read_auto_land_policy "$TMPDIR_TEST/CLAUDE.md"
  [ "$status" -eq 0 ]
  [ "$output" = "high" ]
}

@test "read_auto_land_policy: extracts 'high' across a blank line between heading and value" {
  # Adversarial case from the bead: the previous grep -A1 implementation
  # only captured the heading + 1 line; a blank line between heading and
  # value meant the real setting was silently dropped and the default
  # ("all") was returned regardless of what CLAUDE.md said. The awk
  # implementation walks the whole section so the blank line is harmless.
  cat > "$TMPDIR_TEST/CLAUDE.md" <<'EOF'
# Proj

## Confidence Routing

auto-land: high

## After
EOF
  run read_auto_land_policy "$TMPDIR_TEST/CLAUDE.md"
  [ "$status" -eq 0 ]
  [ "$output" = "high" ]
}

@test "read_auto_land_policy: extracts 'none'" {
  cat > "$TMPDIR_TEST/CLAUDE.md" <<'EOF'
## Confidence Routing

auto-land: none
EOF
  run read_auto_land_policy "$TMPDIR_TEST/CLAUDE.md"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "read_auto_land_policy: ignores a commented-out alternative line" {
  # Adversarial case from the bead: a naive grep "auto-land:" matches the
  # commented line too. The awk regex requires optional whitespace then
  # "auto-land:" at the start of the line, so "# auto-land: high" is
  # skipped and the real setting "all" wins.
  cat > "$TMPDIR_TEST/CLAUDE.md" <<'EOF'
## Confidence Routing

# auto-land: high
auto-land: all
EOF
  run read_auto_land_policy "$TMPDIR_TEST/CLAUDE.md"
  [ "$status" -eq 0 ]
  [ "$output" = "all" ]
}

@test "read_auto_land_policy: stops at the next '## ' heading" {
  # A setting in a later section must not be harvested. Binds the extractor
  # to the routing section specifically, not to "any auto-land: in the file".
  # Falls back to the documented default ('high') since the routing section
  # itself has no setting.
  cat > "$TMPDIR_TEST/CLAUDE.md" <<'EOF'
## Confidence Routing

(prose, no setting)

## Other section

auto-land: all
EOF
  run read_auto_land_policy "$TMPDIR_TEST/CLAUDE.md"
  [ "$status" -eq 0 ]
  [ "$output" = "high" ]
}

@test "read_auto_land_policy: strips trailing whitespace from the value" {
  printf '%s\n' \
    '## Confidence Routing' \
    '' \
    'auto-land: high   ' \
    > "$TMPDIR_TEST/CLAUDE.md"
  run read_auto_land_policy "$TMPDIR_TEST/CLAUDE.md"
  [ "$status" -eq 0 ]
  [ "$output" = "high" ]
}

@test "read_auto_land_policy: smoke — real CLAUDE.md yields a known-good policy" {
  # The real CLAUDE.md in this repo declares auto-land: all. Pins the
  # contract that the shipped template is parseable by the extractor.
  run read_auto_land_policy "$PROJECT_ROOT/CLAUDE.md"
  [ "$status" -eq 0 ]
  [[ "$output" == "all" || "$output" == "high" || "$output" == "none" ]]
}

# --- should_auto_land ---------------------------------------------------

@test "should_auto_land: policy=all, any confidence -> true" {
  for c in HIGH LOW ""; do
    run should_auto_land "$c" "all"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ] || { echo "failed for confidence=$c"; return 1; }
  done
}

@test "should_auto_land: policy=high, HIGH -> true" {
  run should_auto_land "HIGH" "high"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "should_auto_land: policy=high, LOW -> false" {
  run should_auto_land "LOW" "high"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "should_auto_land: policy=none -> false for every confidence" {
  for c in HIGH LOW ""; do
    run should_auto_land "$c" "none"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ] || { echo "failed for confidence=$c"; return 1; }
  done
}

@test "should_auto_land: unknown policy falls back to safer 'high' default (HIGH -> true)" {
  # A typo in CLAUDE.md (e.g., "auto-land: al") falls back to the new safer
  # default ("high"), not the old permissive default ("all"). HIGH confidence
  # still auto-lands; LOW pauses. This is the downstream-safer choice for a
  # template whose default propagates to every project built on it.
  run should_auto_land "HIGH" "al"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "should_auto_land: unknown policy, LOW -> false (safer default)" {
  # Complement to the above: with an unrecognized policy, LOW does NOT
  # auto-land. The fallback is "high", so a downstream project that
  # mistypes its policy gets paused iterations on LOW rather than silent
  # auto-land.
  run should_auto_land "LOW" "garbage"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

# --- compute_retry_state ------------------------------------------------

@test "compute_retry_state: empty failed_bead -> noop, state unchanged" {
  run compute_retry_state "" "some-bead" "2" "3"
  [ "$status" -eq 0 ]
  [ "$output" = "2|some-bead|noop" ]
}

@test "compute_retry_state: same bead failing again increments count" {
  run compute_retry_state "agent-template-abc" "agent-template-abc" "1" "3"
  [ "$status" -eq 0 ]
  [ "$output" = "2|agent-template-abc|continue" ]
}

@test "compute_retry_state: new bead failing resets count to 1" {
  # Reset-on-new-bead is called out explicitly in the bead acceptance: a
  # fresh bead must not inherit the predecessor's fail count.
  run compute_retry_state "agent-template-xyz" "agent-template-abc" "2" "3"
  [ "$status" -eq 0 ]
  [ "$output" = "1|agent-template-xyz|continue" ]
}

@test "compute_retry_state: reaching MAX_RETRIES triggers escalate" {
  # 2 prior fails + 1 more == 3 == MAX_RETRIES. Caller sees "escalate".
  run compute_retry_state "agent-template-abc" "agent-template-abc" "2" "3"
  [ "$status" -eq 0 ]
  [ "$output" = "3|agent-template-abc|escalate" ]
}

@test "compute_retry_state: first failure of a bead with MAX_RETRIES=1 escalates immediately" {
  # Boundary: when max_retries is 1, any single failure must escalate.
  # A naive strict-less-than check would give the agent one free failure
  # beyond the stated max.
  run compute_retry_state "agent-template-abc" "" "0" "1"
  [ "$status" -eq 0 ]
  [ "$output" = "1|agent-template-abc|escalate" ]
}

@test "compute_retry_state: starting fresh (empty last) -> count=1, continue" {
  run compute_retry_state "agent-template-abc" "" "0" "3"
  [ "$status" -eq 0 ]
  [ "$output" = "1|agent-template-abc|continue" ]
}

# --- extract_prereq_bead_id ---------------------------------------------

@test "extract_prereq_bead_id: excludes the active-bead header, returns the first real prereq" {
  # Adversarial case from the bead: `bd dep list <X>` output begins with
  # "X depends on:" whose bead-id token matches the same regex used to
  # pick the prerequisite. A naive head -1 returns the active bead itself,
  # so ralph.sh would re-update ACTIVE_BEAD to status=open (a no-op since
  # it was just unclaimed) and never re-open the real prerequisite. Binding
  # the extraction to "first id that is NOT the active bead" fixes this.
  input="📋 agent-template-6ij depends on:

  agent-template-4mw: Add pre-push hook that re-runs the verification gate [P1] (closed) via blocks
  agent-template-mhd: Add automated parser tests for hook parsers (bats suite) [P1] (closed) via blocks"
  run bash -c 'source "$0"; echo "$1" | extract_prereq_bead_id "$2"' \
    "$PROJECT_ROOT/scripts/ralph/lib.sh" "$input" "agent-template-6ij"
  [ "$status" -eq 0 ]
  [ "$output" = "agent-template-4mw" ]
}

@test "extract_prereq_bead_id: returns empty when the only match is the active bead" {
  # "X has no dependencies" path — only the active bead id appears in the
  # output. After exclusion, no match remains. Must return empty (not the
  # active bead) so the caller skips the re-open step.
  input="agent-template-6ij has no dependencies"
  run bash -c 'source "$0"; echo "$1" | extract_prereq_bead_id "$2"' \
    "$PROJECT_ROOT/scripts/ralph/lib.sh" "$input" "agent-template-6ij"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "extract_prereq_bead_id: returns empty on input with no bead-id-shaped tokens" {
  # Deliberately free of the pattern `[a-z][-a-z0-9]*-[a-z0-9]{2,}`: no
  # dashed lowercase tokens, no digit-bearing words. Confirms the function
  # does not hallucinate a match when the output is pure prose (e.g., a
  # future bd error message that says only "command failed" or similar).
  run bash -c 'source "$0"; echo "$1" | extract_prereq_bead_id "$2"' \
    "$PROJECT_ROOT/scripts/ralph/lib.sh" "nothing matches here" "agent-template-6ij"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "extract_prereq_bead_id: skips a dashed prose word only when that word is the active bead" {
  # Adversarial case: the regex matches any `[a-z][-a-z0-9]*-[a-z0-9]{2,}`,
  # so a bead title containing a dashed word like "pre-push" is a match.
  # In real `bd dep list` output the prereq bead id always appears before
  # its title on the same line, so grep -o (which returns matches in
  # order) picks the bead id first. This test pins that ordering so a
  # future refactor to multiline or split-word handling does not break it.
  input="  agent-template-4mw: Add pre-push hook for gate re-run [P1] (closed) via blocks"
  run bash -c 'source "$0"; echo "$1" | extract_prereq_bead_id "$2"' \
    "$PROJECT_ROOT/scripts/ralph/lib.sh" "$input" "agent-template-6ij"
  [ "$status" -eq 0 ]
  [ "$output" = "agent-template-4mw" ]
}

@test "extract_prereq_bead_id: handles multiple prereqs, returns only the first" {
  input="agent-template-6ij depends on:

  agent-template-first: title one
  agent-template-second: title two"
  run bash -c 'source "$0"; echo "$1" | extract_prereq_bead_id "$2"' \
    "$PROJECT_ROOT/scripts/ralph/lib.sh" "$input" "agent-template-6ij"
  [ "$status" -eq 0 ]
  [ "$output" = "agent-template-first" ]
}

# --- run_gate ------------------------------------------------------------

@test "run_gate: writes PASS and returns 0 when gate command succeeds" {
  # The happy path: honest gate, honest result. Covers the post-agent
  # re-run that ralph.sh does on BEAD_DONE to replace the prior
  # <gate-result> self-report. Uses `true` as a trivial passing gate so
  # the test cost is zero — the real gate has its own coverage in
  # tests/gate/gate.bats.
  result_file="$TMPDIR_TEST/.last-gate-result"
  run run_gate "true" "$result_file"
  [ "$status" -eq 0 ]
  [ -f "$result_file" ]
  [ "$(cat "$result_file")" = "PASS" ]
}

@test "run_gate: writes FAIL and returns non-zero when gate command fails" {
  # The property that keeps an agent from BEAD_DONE-ing over red code:
  # a failing gate writes FAIL and returns non-zero. The pre-push hook
  # then sees FAIL in .last-gate-result and blocks the push (or re-runs
  # and agrees). If this regresses to soft-fail (always writes PASS),
  # the self-report trust gap quietly re-opens.
  result_file="$TMPDIR_TEST/.last-gate-result"
  run run_gate "false" "$result_file"
  [ "$status" -ne 0 ]
  [ -f "$result_file" ]
  [ "$(cat "$result_file")" = "FAIL" ]
}

@test "run_gate: writes SKIPPED and returns non-zero on empty gate command" {
  # Empty gate_cmd means the extractor (gate_command_extract) found no
  # fenced block under ## Verification Gate. Fail closed: return non-zero
  # and record SKIPPED so the caller does not treat "I didn't run
  # anything" as PASS. A callers-trust-exit-code caller BLOCKS here; a
  # callers-trust-file caller sees SKIPPED and escalates.
  result_file="$TMPDIR_TEST/.last-gate-result"
  run run_gate "" "$result_file"
  [ "$status" -ne 0 ]
  [ -f "$result_file" ]
  [ "$(cat "$result_file")" = "SKIPPED" ]
}

@test "run_gate: writes SKIPPED (not FAIL) when gate is absent — distinguishes 'missing' from 'red'" {
  # Structural: the three values PASS / FAIL / SKIPPED must all be
  # distinguishable, because the pre-push hook reads the file. A
  # SKIPPED-as-FAIL collapse would make "gate ran and failed" and "gate
  # was never found" look identical to downstream readers, which would
  # Goodhart the pre-push divergence check.
  result_file="$TMPDIR_TEST/.last-gate-result"
  run run_gate "" "$result_file"
  [ "$status" -ne 0 ]
  [ "$(cat "$result_file")" != "FAIL" ]
  [ "$(cat "$result_file")" != "PASS" ]
}

@test "run_gate: overwrites a prior stale result rather than appending" {
  # Adversarial case: a prior iteration wrote PASS; a current failing
  # gate must overwrite, not append. A naive `>>` would leave PASS on
  # the first line and FAIL on the second, and `tr -d '[:space:]'` in
  # the pre-push hook would read "PASSFAIL" — neither value — and skip
  # its divergence logic entirely. `>` truncation is the binding here.
  result_file="$TMPDIR_TEST/.last-gate-result"
  printf 'PASS\n' > "$result_file"
  run run_gate "false" "$result_file"
  [ "$status" -ne 0 ]
  [ "$(cat "$result_file")" = "FAIL" ]
}

# --- confidence.log bead-id source -------------------------------------
#
# Regression bead agent-template-65s: ralph.sh's two BEAD_DONE confidence.log
# lines used `${_RALPH_ACTIVE_BEAD:-unknown}`, but _RALPH_ACTIVE_BEAD is empty
# whenever an iter starts with no in-progress bead — the agent then picks up
# a fresh bead via _ralph_bead_ready during the iter, and that bead's id is
# stored in _RALPH_BEAD_ID. The result was `bead=unknown` on every successful
# BEAD_DONE iter that started clean (≈all of them after a healthy iter), and
# archive_schema_check filtered those out before requiring archive entries —
# so the parser silently passed on the wrong input. The fix references
# _RALPH_BEAD_ID, set at the iter top from either the resumed active bead or
# _ralph_bead_ready, so it always names the bead the agent will work on.
#
# Test strategy: extract the actual log-emit lines from ralph.sh and eval
# them under the variable state that reproduces the bug condition. Eval'ing
# the real source line (rather than re-implementing it) means a regression
# to `_RALPH_ACTIVE_BEAD` will surface here even if the new code is in a
# different shape than today's. Both BEAD_DONE log lines are covered (the
# auto-land branch and the no-confidence/NONE branch).

@test "ralph.sh BEAD_DONE log line uses the picked-up bead id when iter started clean" {
  _load_ralph_helpers
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"

  # Extract the BEAD_DONE _ralph_emit_log call from the auto-land branch.
  # Identified by its `auto_land=` middle field, unique to this line.
  log_line=$(awk '/^[[:space:]]*_ralph_emit_log .*auto_land=/ { print; exit }' "$ralph")
  [ -n "$log_line" ]

  # Reproduce the bug condition: no in-progress bead at iter start, fresh
  # bead picked up via _ralph_bead_ready. Pre-fix this would emit
  # `bead=unknown`; post-fix it emits the picked-up id.
  _RALPH_I=1
  _RALPH_ACTIVE_BEAD=""
  _RALPH_BEAD_ID="agent-template-xyz"
  _RALPH_BEAD_TYPE="impl"
  _RALPH_BEAD_TITLE="impl: do the thing"
  _RALPH_BEAD_DONE=true
  _RALPH_CONFIDENCE="HIGH"
  _RALPH_POLICY="all"
  _RALPH_AUTO_LAND="true"
  _RALPH_GATE_RESULT="PASS"
  _RALPH_COMPLETED_SUMMARY="feat: [agent-template-xyz] - did the thing"
  _RALPH_CONFIDENCE_LOG="$TMPDIR_TEST/confidence.log"
  : > "$_RALPH_CONFIDENCE_LOG"

  eval "$log_line"

  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" == *"bead=agent-template-xyz"* ]] || { echo "Got: $emitted"; return 1; }
  [[ "$emitted" != *"bead=unknown"* ]] || { echo "Got: $emitted"; return 1; }
}

@test "ralph.sh confidence=NONE log line uses the picked-up bead id when iter started clean" {
  _load_ralph_helpers
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"

  # Extract the confidence=NONE branch _ralph_emit_log call (BEAD_DONE seen
  # but no confidence verdict — e.g., a bead_done=false path that still wants
  # to log the iter outcome). Identified by `confidence=NONE`.
  log_line=$(awk '/^[[:space:]]*_ralph_emit_log .*confidence=NONE/ { print; exit }' "$ralph")
  [ -n "$log_line" ]

  _RALPH_I=1
  _RALPH_ACTIVE_BEAD=""
  _RALPH_BEAD_ID="agent-template-xyz"
  _RALPH_BEAD_TYPE="impl"
  _RALPH_BEAD_TITLE="impl: do the thing"
  _RALPH_BEAD_DONE=true
  _RALPH_GATE_RESULT="PASS"
  _RALPH_COMPLETED_SUMMARY="feat: [agent-template-xyz] - did the thing"
  _RALPH_CONFIDENCE_LOG="$TMPDIR_TEST/confidence.log"
  : > "$_RALPH_CONFIDENCE_LOG"

  eval "$log_line"

  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" == *"bead=agent-template-xyz"* ]] || { echo "Got: $emitted"; return 1; }
  [[ "$emitted" != *"bead=unknown"* ]] || { echo "Got: $emitted"; return 1; }
}

# --- _ralph_load_bead_meta + _ralph_sanitize_log_field -----------------
#
# Bead agent-template-d92: ralph.sh hydrates bead type/title/description
# from a single `bd show <id> --json` call so the banner, the confidence.log
# line, and the iteration footer all share one snapshot. The jq path
# normalizes bd <0.49 (object) and bd >=0.49 (array-of-one) responses so a
# version bump does not silently empty the title (the prior `_ralph_bead_title`
# bug). The sanitizer keeps free-form text from breaking the line-oriented
# parsers in scripts/hooks/parsers.sh.
#
# These helpers live in ralph.sh (not lib.sh) — ralph.sh is meant to be
# sourced and runs the agent loop, so we extract the function definitions
# via awk and eval them in isolation. Same shape used by the log-emit
# tests above.

_load_ralph_helpers() {
  local fns
  fns=$(awk '
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{[[:space:]]*$/ { in_fn=1; print; next }
    in_fn && /^\}[[:space:]]*$/ { in_fn=0; print; next }
    in_fn { print }
  ' "$PROJECT_ROOT/scripts/ralph/ralph.sh")
  eval "$fns"
}

_install_bd_stub() {
  mkdir -p "$TMPDIR_TEST/bin"
  cat > "$TMPDIR_TEST/bin/bd" <<EOF
#!/bin/bash
cat <<'BD_JSON'
$1
BD_JSON
EOF
  chmod +x "$TMPDIR_TEST/bin/bd"
  PATH="$TMPDIR_TEST/bin:$PATH"
}

@test "_ralph_sanitize_log_field: plain text passes through unchanged" {
  _load_ralph_helpers
  run _ralph_sanitize_log_field "hello world"
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

@test "_ralph_sanitize_log_field: collapses tabs and newlines to a single space" {
  # Multi-line / tab-bearing titles or commit subjects must not break the
  # line-oriented confidence.log. tr+squeeze keeps the field as one token-
  # stream the awk-style parsers in scripts/hooks/parsers.sh can read.
  _load_ralph_helpers
  run _ralph_sanitize_log_field $'foo\tbar\n  baz'
  [ "$status" -eq 0 ]
  [ "$output" = "foo bar baz" ]
}

@test "_ralph_sanitize_log_field: replaces double quotes with single quotes" {
  # The value lives inside title=\"...\" / completed=\"...\" in the log line.
  # An embedded `"` would close the field early and corrupt every following
  # field — the sanitizer downgrades it to `'` so the surrounding quotes hold.
  _load_ralph_helpers
  run _ralph_sanitize_log_field 'with "embedded" quotes'
  [ "$status" -eq 0 ]
  [ "$output" = "with 'embedded' quotes" ]
}

@test "_ralph_sanitize_log_field: truncates strings over 160 chars with ... marker" {
  # Long descriptions otherwise push real fields off the visible end of an
  # awk view. 160 + ellipsis is the working limit; the truncation point is
  # 157 + "..." so total stays at 160.
  _load_ralph_helpers
  longstr=$(printf 'x%.0s' {1..200})
  run _ralph_sanitize_log_field "$longstr"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 160 ]
  [[ "$output" == *"..." ]] || { echo "missing ... marker: $output"; return 1; }
}

@test "_ralph_sanitize_log_field: 160-char string at the boundary stays unchanged" {
  # Boundary pin: 160 stays as-is; 161 truncates. A `>` vs `>=` flip would
  # silently shift the cut by one char.
  _load_ralph_helpers
  exact=$(printf 'a%.0s' {1..160})
  run _ralph_sanitize_log_field "$exact"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 160 ]
  [[ "$output" != *"..." ]] || { echo "spurious ... marker: $output"; return 1; }
}

@test "_ralph_sanitize_log_field: empty input returns empty" {
  _load_ralph_helpers
  run _ralph_sanitize_log_field ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_ralph_load_bead_meta: object response (bd <0.49) populates type/title/desc" {
  # The pre-0.49 shape — `bd show <id> --json` returns a JSON object.
  _load_ralph_helpers
  _install_bd_stub '{"title":"impl: foo bar","description":"do the thing","issue_type":"task"}'
  _ralph_load_bead_meta "any-id"
  [ "$_RALPH_BEAD_TITLE" = "impl: foo bar" ]
  [ "$_RALPH_BEAD_DESCRIPTION" = "do the thing" ]
  [ "$_RALPH_BEAD_TYPE" = "impl" ]
}

@test "_ralph_load_bead_meta: array-of-one response (bd >=0.49) populates type/title/desc" {
  # The post-0.49 shape — bd returns an array. Without the (if type==array)
  # guard, jq errored "Cannot index array with string" and silently emptied
  # the title (the bug this bead replaces).
  _load_ralph_helpers
  _install_bd_stub '[{"title":"review: audit foo","description":"R","issue_type":"task"}]'
  _ralph_load_bead_meta "any-id"
  [ "$_RALPH_BEAD_TITLE" = "review: audit foo" ]
  [ "$_RALPH_BEAD_DESCRIPTION" = "R" ]
  [ "$_RALPH_BEAD_TYPE" = "review" ]
}

@test "_ralph_load_bead_meta: every loop-taxonomy keyword resolves from the title" {
  # Pin every accepted prefix in the regex (impl/review/pare/pare-down/
  # compound/research). A future drop of one would silently fall through
  # to .issue_type — which uniformly returns 'task' in this repo's flow.
  _load_ralph_helpers
  for kw in impl review pare pare-down compound research; do
    _install_bd_stub "{\"title\":\"$kw: thing\",\"description\":\"\",\"issue_type\":\"task\"}"
    _ralph_load_bead_meta "any-id"
    [ "$_RALPH_BEAD_TYPE" = "$kw" ] || { echo "kw=$kw got=$_RALPH_BEAD_TYPE"; return 1; }
  done
}

@test "_ralph_load_bead_meta: title without a keyword falls back to .issue_type" {
  # Unconventional / legacy titles (no `<keyword>:` prefix) still need a
  # type to display. bd's CLI taxonomy is the documented fallback.
  _load_ralph_helpers
  _install_bd_stub '{"title":"banana fix","description":"X","issue_type":"bug"}'
  _ralph_load_bead_meta "any-id"
  [ "$_RALPH_BEAD_TYPE" = "bug" ]
}

@test "_ralph_load_bead_meta: empty bd output leaves globals empty (no crash)" {
  # bd missing or returning empty must not crash the loop under set -u.
  # Globals stay empty; banner gracefully prints `[] — ` with no Description.
  _load_ralph_helpers
  mkdir -p "$TMPDIR_TEST/bin"
  printf '#!/bin/bash\nexit 0\n' > "$TMPDIR_TEST/bin/bd"
  chmod +x "$TMPDIR_TEST/bin/bd"
  PATH="$TMPDIR_TEST/bin:$PATH"
  _ralph_load_bead_meta "any-id"
  [ -z "$_RALPH_BEAD_TITLE" ]
  [ -z "$_RALPH_BEAD_DESCRIPTION" ]
  [ -z "$_RALPH_BEAD_TYPE" ]
}

# --- ralph.sh banner shape ---------------------------------------------

@test "ralph.sh banner prints [type] — title and Description line" {
  # Extract the banner block (# --- Show upcoming work --- through the
  # divider line) and eval it under hydrated globals. The bead description
  # mandates `[type] — title` on its own line and `Description: <desc>` as
  # a separate line so the operator sees the bead's contract pre-run.
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  block=$(awk '
    /^[[:space:]]*# --- Show upcoming work/ { capture=1 }
    capture && /^[[:space:]]*echo "---/ { print; exit }
    capture { print }
  ' "$ralph")
  [ -n "$block" ]

  # Stub the helpers we depend on; eval the block under controlled state.
  _ralph_load_bead_meta() {
    _RALPH_BEAD_TYPE="impl"
    _RALPH_BEAD_TITLE="impl: foo"
    _RALPH_BEAD_DESCRIPTION="some description"
  }
  _ralph_bead_ready() { echo "agent-template-xyz"; }
  _RALPH_ACTIVE_BEAD=""

  out=$(eval "$block")
  [[ "$out" == *"[impl] — impl: foo"* ]] || { echo "Got: $out"; return 1; }
  [[ "$out" == *"Description: some description"* ]] || { echo "Got: $out"; return 1; }
}

@test "ralph.sh banner omits Description line when description is empty" {
  # Pin that an empty description does not print a bare `Description:` line —
  # the gating is `[[ -n "$_RALPH_BEAD_DESCRIPTION" ]]`.
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  block=$(awk '
    /^[[:space:]]*# --- Show upcoming work/ { capture=1 }
    capture && /^[[:space:]]*echo "---/ { print; exit }
    capture { print }
  ' "$ralph")

  _ralph_load_bead_meta() {
    _RALPH_BEAD_TYPE="impl"
    _RALPH_BEAD_TITLE="impl: foo"
    _RALPH_BEAD_DESCRIPTION=""
  }
  _ralph_bead_ready() { echo "agent-template-xyz"; }
  _RALPH_ACTIVE_BEAD=""

  out=$(eval "$block")
  [[ "$out" == *"[impl] — impl: foo"* ]]
  [[ "$out" != *"Description:"* ]] || { echo "spurious Description line: $out"; return 1; }
}

# --- ralph.sh COMPLETE routing -----------------------------------------

@test "ralph.sh COMPLETE branch exits only when tracker_has_unfinished_beads says none remain" {
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  block=$(awk '
    /^[[:space:]]*# Check for completion signal/ { capture=1 }
    capture && /^[[:space:]]*# Check for rate limit signal/ { exit }
    capture { print }
  ' "$ralph")
  [ -n "$block" ]

  _RALPH_PROMISE_SIGNAL="COMPLETE"
  _RALPH_I=4
  _RALPH_MAX_ITERATIONS=30
  FINISH_CALLED=""
  finish() { FINISH_CALLED="$1|$2"; }
  tracker_has_unfinished_beads() { return 1; }

  set +e
  for _loop_once in 1; do
    eval "$block"
  done
  set -e

  [ "$FINISH_CALLED" = "0|Ralph completed all tasks at iteration 4 of 30." ]
}

@test "ralph.sh COMPLETE branch rejects COMPLETE when unfinished beads remain" {
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  block=$(awk '
    /^[[:space:]]*# Check for completion signal/ { capture=1 }
    capture && /^[[:space:]]*# Check for rate limit signal/ { exit }
    capture { print }
  ' "$ralph")
  [ -n "$block" ]

  _RALPH_PROMISE_SIGNAL="COMPLETE"
  _RALPH_I=4
  _RALPH_MAX_ITERATIONS=30
  FINISH_CALLED=""
  finish() { FINISH_CALLED="$1|$2"; }
  tracker_has_unfinished_beads() { return 0; }

  out_file="$TMPDIR_TEST/complete-warning.txt"
  : > "$out_file"
  set +e
  for _loop_once in 1; do
    eval "$block" > "$out_file"
  done
  set -e
  out=$(cat "$out_file")

  [ -z "$FINISH_CALLED" ]
  [ -z "$_RALPH_PROMISE_SIGNAL" ]
  [[ "$out" == *"WARNING: Agent emitted COMPLETE, but open or in-progress beads remain. Continuing."* ]] \
    || { echo "Got: $out"; return 1; }
}

@test "ralph.sh COMPLETE branch exits safely when tracker state cannot be verified" {
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  block=$(awk '
    /^[[:space:]]*# Check for completion signal/ { capture=1 }
    capture && /^[[:space:]]*# Check for rate limit signal/ { exit }
    capture { print }
  ' "$ralph")
  [ -n "$block" ]

  _RALPH_PROMISE_SIGNAL="COMPLETE"
  _RALPH_I=4
  _RALPH_MAX_ITERATIONS=30
  FINISH_CALLED=""
  finish() { FINISH_CALLED="$1|$2"; }
  tracker_has_unfinished_beads() { return 2; }

  set +e
  for _loop_once in 1; do
    eval "$block"
  done
  set -e

  [ "$FINISH_CALLED" = "1|Ralph received COMPLETE at iteration 4, but tracker state could not be verified. Exiting safely." ]
}

# --- ralph.sh confidence.log emission ----------------------------------
#
# Prior to bead agent-template-kb6 the loop carried five separately-
# interpolated `echo "[ts] iter=N ..." >> log` lines (BLOCKED, REWORK,
# ESCALATION, BEAD_DONE-with-confidence, BEAD_DONE-without-confidence)
# each with its own copy of the prefix / suffix and per-branch field set.
# kb6 collapsed them through `_ralph_emit_log` (ralph.sh):
#   _ralph_emit_log <status> <bead-id> <middle-fields> [include-completed]
# The two tests below split that contract: the helper-coverage test pins
# the helper's own shape and sanitization; the smoke test ensures every
# call site in ralph.sh still produces a shape carrying bead_type and
# (for BEAD_DONE) completed, so a regression at either layer surfaces.

@test "_ralph_emit_log: builds prefix/suffix shape with optional status, middle, and completed" {
  _load_ralph_helpers
  _RALPH_I=7
  _RALPH_BEAD_TYPE="impl"
  _RALPH_BEAD_TITLE=$'has\ttab and "quote"'
  _RALPH_COMPLETED_SUMMARY="feat: [agent-template-xyz] - did the thing"
  _RALPH_CONFIDENCE_LOG="$TMPDIR_TEST/confidence.log"

  # (a) status word + middle + no completed (BLOCKED/REWORK/ESCALATION shape).
  : > "$_RALPH_CONFIDENCE_LOG"
  _ralph_emit_log "BLOCKED" "agent-template-xyz" "reason=missing dep"
  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" == *"iter=7 BLOCKED bead=agent-template-xyz bead_type=impl reason=missing dep"* ]] \
    || { echo "Got: $emitted"; return 1; }
  # Title is sanitized (tab → space, " → ').
  [[ "$emitted" == *"title=\"has tab and 'quote'\""* ]] || { echo "Got: $emitted"; return 1; }
  # No completed= field when caller omits the flag.
  [[ "$emitted" != *"completed="* ]] || { echo "spurious completed: $emitted"; return 1; }
  # archive_schema_check's `grep -oE 'bead=[^ ]+'` still finds the bead id and
  # is not confused by the adjacent `bead_type=` field.
  [ "$(echo "$emitted" | grep -oE 'bead=[^ ]+')" = "bead=agent-template-xyz" ]

  # (b) empty status + completed=yes (BEAD_DONE shape).
  : > "$_RALPH_CONFIDENCE_LOG"
  _ralph_emit_log "" "agent-template-xyz" \
    "bead_done=true confidence=HIGH gate_result=PASS" "yes"
  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" == *"iter=7 bead=agent-template-xyz bead_type=impl bead_done=true confidence=HIGH gate_result=PASS"* ]] \
    || { echo "Got: $emitted"; return 1; }
  [[ "$emitted" == *'completed="feat: [agent-template-xyz] - did the thing"'* ]] \
    || { echo "Got: $emitted"; return 1; }
  # No double "BLOCKED"/"REWORK"/"ESCALATION" word slipped in for empty status.
  [[ "$emitted" != *" BLOCKED "* && "$emitted" != *" REWORK "* && "$emitted" != *" ESCALATION "* ]] \
    || { echo "spurious status word: $emitted"; return 1; }

  # (c) empty bead defaults to "unknown" (covers the {var:-unknown} fallback
  # the call sites lean on for pre-claim iters).
  : > "$_RALPH_CONFIDENCE_LOG"
  _ralph_emit_log "BLOCKED" "" "reason=x"
  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" == *"bead=unknown bead_type=impl"* ]] || { echo "Got: $emitted"; return 1; }
}

@test "ralph.sh _ralph_emit_log call sites: each branch emits bead_type, title, and completed-where-expected" {
  # Smoke test: extract each of the five _ralph_emit_log call sites from
  # the live source, eval under hydrated globals, and assert the emitted
  # log line carries bead_type, the sanitized title, and (for the two
  # BEAD_DONE branches) completed. A regression that drops a field in any
  # one branch — or wires the wrong middle-field set — surfaces here.
  _load_ralph_helpers
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  _RALPH_I=1
  _RALPH_BEAD_TYPE="impl"
  _RALPH_BEAD_TITLE="impl: do the thing"
  _RALPH_CONFIDENCE_LOG="$TMPDIR_TEST/confidence.log"

  # Each entry: <pattern matched against the call site> | <expect-completed>
  # | <extra hydrated vars (eval'd before the call)>.
  while IFS='|' read -r pattern expect_completed setup; do
    [ -z "$pattern" ] && continue
    call=$(awk -v pat="$pattern" '$0 ~ pat { print; exit }' "$ralph")
    [ -n "$call" ] || { echo "no call site matched: $pattern"; return 1; }
    : > "$_RALPH_CONFIDENCE_LOG"
    eval "$setup"
    eval "$call"
    emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
    [[ "$emitted" == *"bead_type=impl"* ]] \
      || { echo "[$pattern] missing bead_type: $emitted"; return 1; }
    [[ "$emitted" == *'title="impl: do the thing"'* ]] \
      || { echo "[$pattern] missing title: $emitted"; return 1; }
    if [ "$expect_completed" = "yes" ]; then
      [[ "$emitted" == *'completed="feat: [agent-template-xyz] - did the thing"'* ]] \
        || { echo "[$pattern] missing completed: $emitted"; return 1; }
    else
      [[ "$emitted" != *"completed="* ]] \
        || { echo "[$pattern] unexpected completed: $emitted"; return 1; }
    fi
  done <<'EOF'
_ralph_emit_log "BLOCKED"|no|_RALPH_ACTIVE_BEAD="agent-template-xyz"; _RALPH_BLOCKED_REASON="missing dep"
_ralph_emit_log "REWORK"|no|_RALPH_ACTIVE_BEAD="agent-template-xyz"; _RALPH_REWORK_REASON="prereq incomplete"
_ralph_emit_log "ESCALATION"|no|_RALPH_FAILED_BEAD="agent-template-xyz"; _RALPH_FAIL_COUNT=3
_ralph_emit_log .*auto_land=|yes|_RALPH_BEAD_ID="agent-template-xyz"; _RALPH_BEAD_DONE=true; _RALPH_CONFIDENCE="HIGH"; _RALPH_POLICY="all"; _RALPH_AUTO_LAND="true"; _RALPH_GATE_RESULT="PASS"; _RALPH_COMPLETED_SUMMARY="feat: [agent-template-xyz] - did the thing"
_ralph_emit_log .*confidence=NONE|yes|_RALPH_BEAD_ID="agent-template-xyz"; _RALPH_BEAD_DONE=true; _RALPH_GATE_RESULT="PASS"; _RALPH_COMPLETED_SUMMARY="feat: [agent-template-xyz] - did the thing"
EOF
}

@test "ralph/hooks bash surface: no function-local collides with a zsh read-only special parameter" {
  # Regression for agent-template-uez: ralph.sh:_ralph_emit_log declared
  # `local status="$1"`. zsh reserves `status` as a read-only special
  # parameter (alias of `$?`), so under a sourced zsh shell the function
  # aborted with `read-only variable: status` — and because the script is
  # sourced from the user's interactive shell, the unwind skipped
  # `_ralph_cleanup`, leaking `set -u` into the user's prompt (RPROMPT /
  # VIRTUAL_ENV prompt-segment errors).
  #
  # Bind the property: every bash file the loop sources or the hooks chain
  # depends on is sourced from zsh in the wild (ralph.sh directly; lib.sh
  # and parsers.sh transitively). A function-local whose name matches a
  # zsh read-only special is a latent abort. The set below is the known
  # zsh read-only / special-parameter names whose `local`/`typeset`
  # collision is fatal in a sourced context.
  local files=(
    "$PROJECT_ROOT/scripts/ralph/ralph.sh"
    "$PROJECT_ROOT/scripts/ralph/lib.sh"
    "$PROJECT_ROOT/scripts/hooks/parsers.sh"
    "$PROJECT_ROOT/scripts/hooks/install.sh"
  )
  local reserved=(status pipestatus argv funcstack funcfiletrace funcsourcetrace signals seconds histcmd history lineno)
  local f name hit
  for f in "${files[@]}"; do
    [ -f "$f" ] || { echo "missing file: $f"; return 1; }
    for name in "${reserved[@]}"; do
      hit=$(grep -nE "^[[:space:]]*(local|typeset|declare)[[:space:]]+${name}([[:space:]]|=)" "$f" || true)
      if [ -n "$hit" ]; then
        echo "zsh read-only special parameter '$name' used as a function-local in $f:"
        echo "$hit"
        return 1
      fi
    done
  done
}

# --- ralph.sh iteration footer -----------------------------------------

@test "ralph.sh iteration footer prints bead context when _RALPH_COMPLETED_SUMMARY is set" {
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  block=$(awk '
    /^[[:space:]]*# Footer:/ { capture=1 }
    capture && /^[[:space:]]*echo "Iteration \$_RALPH_I complete/ { print; exit }
    capture { print }
  ' "$ralph")
  [ -n "$block" ]

  _RALPH_COMPLETED_SUMMARY="feat: [agent-template-xyz] - did the thing"
  _RALPH_BEAD_ID="agent-template-xyz"
  _RALPH_BEAD_TYPE="impl"
  _RALPH_BEAD_TITLE="impl: do the thing"
  _RALPH_I=5

  out=$(eval "$block")
  [[ "$out" == *"agent-template-xyz [impl] — impl: do the thing"* ]] || { echo "Got: $out"; return 1; }
  [[ "$out" == *"Completed: feat: [agent-template-xyz] - did the thing"* ]] || { echo "Got: $out"; return 1; }
  [[ "$out" == *"Iteration 5 complete"* ]]
}

@test "ralph.sh iteration footer omits bead context when _RALPH_COMPLETED_SUMMARY is empty" {
  # Non-BEAD_DONE iters (BLOCKED / REWORK / no-signal) leave the summary
  # empty — the gating prevents a duplicate "this bead was about" line on
  # iters where the routing branch already printed its own status.
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  block=$(awk '
    /^[[:space:]]*# Footer:/ { capture=1 }
    capture && /^[[:space:]]*echo "Iteration \$_RALPH_I complete/ { print; exit }
    capture { print }
  ' "$ralph")

  _RALPH_COMPLETED_SUMMARY=""
  _RALPH_BEAD_ID="agent-template-xyz"
  _RALPH_BEAD_TYPE="impl"
  _RALPH_BEAD_TITLE="impl: do the thing"
  _RALPH_I=5

  out=$(eval "$block")
  [[ "$out" != *"agent-template-xyz [impl]"* ]] || { echo "spurious context: $out"; return 1; }
  [[ "$out" == *"Iteration 5 complete"* ]]
}

@test "_ralph_cleanup unsets the new globals" {
  # The cleanup function must `unset` every new _RALPH_ var so sourcing
  # ralph.sh repeatedly (e.g., in an outer test harness) does not leak
  # stale type/title/desc/summary from a prior run into the next.
  _load_ralph_helpers
  _RALPH_HAD_NOUNSET=0
  _RALPH_BEAD_TYPE="impl"
  _RALPH_BEAD_DESCRIPTION="X"
  _RALPH_COMPLETED_SUMMARY="Y"
  _ralph_cleanup
  [ -z "${_RALPH_BEAD_TYPE:-}" ]
  [ -z "${_RALPH_BEAD_DESCRIPTION:-}" ]
  [ -z "${_RALPH_COMPLETED_SUMMARY:-}" ]
}

# --- BEAD_ID_REGEX drift --------------------------------------------------

@test "BEAD_ID_REGEX in lib.sh matches PARSERS_BEAD_ID_REGEX in parsers.sh byte-for-byte" {
  # The two libraries historically drifted (lib.sh used [a-z], install.sh
  # grep used [a-z_]) and no test compared them. This smoke test is the
  # structural backstop for CLAUDE.md's "Bead id shape lives in exactly
  # one place per library" invariant.
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/ralph/lib.sh"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/hooks/parsers.sh"
  [ -n "$BEAD_ID_REGEX" ]
  [ -n "$PARSERS_BEAD_ID_REGEX" ]
  [ "$BEAD_ID_REGEX" = "$PARSERS_BEAD_ID_REGEX" ]
}
