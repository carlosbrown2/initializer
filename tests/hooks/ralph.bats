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

# --- compute_confidence --------------------------------------------------
#
# Replaces the removed parse_confidence / parse_confidence_bead_done suite.
# Those tests pinned the parser against agent-emitted `<confidence>` tags;
# this suite pins the derivation against observable signals (gate result,
# commit size, touched-paths, retry count). Each downgrade axis is covered
# in isolation so a future edit that drops one can only pass by removing
# the corresponding test — a visible deletion rather than a silent drift.

@test "compute_confidence: gate FAIL returns LOW regardless of other signals" {
  # Terminal rule: a red gate forbids HIGH or MEDIUM no matter how clean
  # everything else looks. If this regresses, compute_confidence becomes a
  # proxy for diff-size rather than for bead outcome.
  run compute_confidence "FAIL" 0 "false" "false" 0
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

@test "compute_confidence: gate SKIPPED is treated as non-PASS (LOW)" {
  # Three-valued .last-gate-result (PASS/FAIL/SKIPPED). SKIPPED means the
  # gate extractor returned empty — unknown gate state. Fail closed to LOW
  # rather than letting an unknown state auto-land.
  run compute_confidence "SKIPPED" 0 "false" "false" 0
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

@test "compute_confidence: empty gate result is treated as non-PASS (LOW)" {
  # Defensive: if the caller forgets to pass gate_result, fall through to
  # LOW. Preserves the "fail closed on unknown gate" property even against
  # a programmer error at the call site.
  run compute_confidence "" 0 "false" "false" 0
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

@test "compute_confidence: gate PASS with no downgrades returns HIGH" {
  # Canonical happy path: green gate, small diff, no risky paths touched,
  # no retries. This is the only configuration that auto-lands under
  # 'auto-land: high', which is the shipped default for the template.
  run compute_confidence "PASS" 100 "false" "false" 0
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "compute_confidence: PASS + retry_count>0 downgrades to MEDIUM" {
  # Any prior failure on this bead is a "the agent struggled" signal.
  # Even a clean final state earns less trust than a first-try success.
  run compute_confidence "PASS" 100 "false" "false" 1
  [ "$status" -eq 0 ]
  [ "$output" = "MEDIUM" ]
}

@test "compute_confidence: PASS + large diff downgrades to MEDIUM" {
  # Diff-size threshold (currently 500 lines) is a heuristic for "enough
  # surface area that a quiet regression could hide." The threshold itself
  # is an implementation detail; what this test pins is that crossing it
  # downgrades. If the threshold moves, update the number here.
  run compute_confidence "PASS" 1000 "false" "false" 0
  [ "$status" -eq 0 ]
  [ "$output" = "MEDIUM" ]
}

@test "compute_confidence: PASS + diff exactly at threshold stays HIGH" {
  # Boundary: the rule is strictly >500, not >=500. A 500-line commit is
  # big but not in the "downgrade" class. Pinning the boundary so a future
  # `>` vs `>=` flip is caught mechanically.
  run compute_confidence "PASS" 500 "false" "false" 0
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "compute_confidence: PASS + touched scripts/hooks/ downgrades to MEDIUM" {
  # Changing the enforcement mechanism is higher-risk than changing code
  # that the enforcement mechanism judges. The downgrade enforces "the
  # author of a hook change should expect human review."
  run compute_confidence "PASS" 100 "true" "false" 0
  [ "$status" -eq 0 ]
  [ "$output" = "MEDIUM" ]
}

@test "compute_confidence: PASS + touched CLAUDE.md downgrades to MEDIUM" {
  # CLAUDE.md is project rules and the gate command itself. A green gate
  # against a CLAUDE.md edit is weaker evidence than a green gate against
  # code, because the gate's own definition may have shifted in the diff.
  run compute_confidence "PASS" 100 "false" "true" 0
  [ "$status" -eq 0 ]
  [ "$output" = "MEDIUM" ]
}

@test "compute_confidence: PASS + two downgrade axes collapse to LOW" {
  # Two independent signals of "this deserves scrutiny" should not average
  # out to MEDIUM. Each downgrade axis counts on its own; two axes mean LOW.
  run compute_confidence "PASS" 1000 "true" "false" 0
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

@test "compute_confidence: PASS + three downgrade axes stay LOW (floor)" {
  # Floor property: additional downgrade axes past two cannot push the
  # verdict below LOW. Prevents a future axis addition from silently
  # introducing a fourth level.
  run compute_confidence "PASS" 1000 "true" "true" 2
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

@test "compute_confidence: defaults for omitted trailing args behave like zeros" {
  # Callers may omit trailing args; the function defaults them to benign
  # values (0 / false) so a programmer error truncating the call does not
  # crash under `set -u` inside compute_confidence. PASS with no provided
  # signals is HIGH — matches the all-clean path above.
  run compute_confidence "PASS"
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
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
  for c in HIGH MEDIUM LOW ""; do
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

@test "should_auto_land: policy=high, MEDIUM -> false" {
  run should_auto_land "MEDIUM" "high"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "should_auto_land: policy=high, LOW -> false" {
  run should_auto_land "LOW" "high"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "should_auto_land: policy=none -> false for every confidence" {
  for c in HIGH MEDIUM LOW ""; do
    run should_auto_land "$c" "none"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ] || { echo "failed for confidence=$c"; return 1; }
  done
}

@test "should_auto_land: unknown policy falls back to safer 'high' default (HIGH -> true)" {
  # A typo in CLAUDE.md (e.g., "auto-land: al") falls back to the new safer
  # default ("high"), not the old permissive default ("all"). HIGH confidence
  # still auto-lands; MEDIUM/LOW pause. This is the downstream-safer choice
  # for a template whose default propagates to every project built on it.
  run should_auto_land "HIGH" "al"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "should_auto_land: unknown policy, MEDIUM -> false (safer default)" {
  # Complement to the above: with an unrecognized policy, MEDIUM does NOT
  # auto-land. Previously this test would have returned "true" because the
  # old fallback was "all"; now it returns "false" because the fallback is
  # "high". A downstream project that mistypes its policy gets paused
  # iterations on MEDIUM rather than silent auto-land.
  run should_auto_land "MEDIUM" "garbage"
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
  # tests/hooks/gate.bats.
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
