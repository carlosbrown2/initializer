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

@test "compute_confidence: legacy 5-arg shape (retry_count int) is ignored, returns HIGH" {
  # Retired axis: retry_count was the 5th positional in the prior shape and
  # downgraded once when >0. Legacy callers (older test fixtures, downstream
  # forks that haven't yet retired the param) still pass an integer like 5.
  # The new 5th positional is recent_followup_ratio (decimal in [0, 1]) and
  # values outside that range are treated as "no signal" — pinning that
  # invariant from the legacy direction so a regression that drops the range
  # check would surface as this test flipping to MEDIUM.
  run compute_confidence "PASS" 100 "false" "false" 5
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "compute_confidence: PASS + saturation ratio at 0.6 boundary stays HIGH (3/5)" {
  # Bracket-low side of the loop_saturation cut. Rule is strict >0.6, so
  # 3/5 = 0.6 stays at the prevailing confidence. Pinning the boundary so a
  # future `>` vs `>=` flip is caught mechanically (paired with the 0.8 test
  # below). The runaway-loop signature is "the loop is operating on a fixed
  # point of self-tightening reviews" — 3/5 is the threshold above which
  # the diagnostic fires.
  run compute_confidence "PASS" 100 "false" "false" 0.6
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "compute_confidence: PASS + saturation ratio just above cut downgrades to MEDIUM (4/5)" {
  # Bracket-high side: 4/5 = 0.8 > 0.6 fires the loop_saturation axis.
  # Paired with the 0.6 boundary test above, this pins the cut from both
  # sides — exactly one of the two tests fails on a `>` vs `>=` flip.
  run compute_confidence "PASS" 100 "false" "false" 0.8
  [ "$status" -eq 0 ]
  [ "$output" = "MEDIUM" ]
}

@test "compute_confidence: PASS + saturation ratio exactly at 0 (no follow-ups) stays HIGH" {
  # Default-shape: ralph.sh passes 0 when no follow-ups in the last 5 closes
  # OR when the AND-suppressor (Phase N impl: / integration- in window) fires.
  # Either way the axis must not downgrade — this is the dominant case in a
  # healthy loop. Adjacent to the legacy-arg test: 5 (legacy) and 0 (default)
  # both stay HIGH but for different reasons (out-of-range vs. in-range-low).
  run compute_confidence "PASS" 100 "false" "false" 0
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
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

@test "compute_confidence: PASS + diff just above threshold (501) downgrades to MEDIUM" {
  # Tight bracket on the just-above side: paired with the 500→HIGH test
  # above, this pins the cut point from both sides. A future `>` vs `>=`
  # flip would silently shift the boundary by one line; with both 500 and
  # 501 pinned, exactly one of the two tests fails on a flip and the
  # diagnostic points at the operator. The wider 1000→MEDIUM test still
  # asserts "well above the cut downgrades" but cannot catch an off-by-one.
  run compute_confidence "PASS" 501 "false" "false" 0
  [ "$status" -eq 0 ]
  [ "$output" = "MEDIUM" ]
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

# --- compute_head_unchanged_for_bead_done -------------------------------
#
# Bead agent-template-nvd: per-iter measurements (diff_lines / touched_hooks /
# touched_claude_md) read HEAD without verifying HEAD has moved since iter
# start. A BEAD_DONE iter that did not commit silently grades the prior
# bead's diff and credits the result to the wrong work. The helper is the
# detection layer; ralph.sh forces gate_result=FAIL when it returns 0.

@test "compute_head_unchanged_for_bead_done: pre==post returns 0 (HEAD did not move)" {
  # The contract: identical SHAs mean BEAD_DONE landed without a commit.
  # Returns 0 (success exit) so callers can use it directly in `if` —
  # `if compute_head_unchanged_for_bead_done ...; then force-FAIL; fi`.
  run compute_head_unchanged_for_bead_done "abc123" "abc123"
  [ "$status" -eq 0 ]
}

@test "compute_head_unchanged_for_bead_done: pre!=post returns 1 (commit landed)" {
  # The happy path: HEAD moved during the iter, so per-iter signals can be
  # trusted. Returns 1 so the `if` branch above does not fire.
  run compute_head_unchanged_for_bead_done "abc123" "def456"
  [ "$status" -eq 1 ]
}

@test "compute_head_unchanged_for_bead_done: real temp repo, no commit -> unchanged" {
  # Drives the helper against the actual `git rev-parse HEAD` shape, not
  # synthetic strings. Reproduces the failure mode: an iter that emits
  # BEAD_DONE without committing — pre and post both point at the same SHA.
  cd "$TMPDIR_TEST"
  git init -q
  git -c user.email=t@t.test -c user.name=t commit --allow-empty -m "init" -q
  pre=$(git rev-parse HEAD)
  post=$(git rev-parse HEAD)
  run compute_head_unchanged_for_bead_done "$pre" "$post"
  [ "$status" -eq 0 ]
}

@test "compute_head_unchanged_for_bead_done: real temp repo, commit between -> moved" {
  # Complement to the above: a commit lands between the two reads, so the
  # helper returns non-zero and ralph.sh proceeds to the real gate run.
  cd "$TMPDIR_TEST"
  git init -q
  git -c user.email=t@t.test -c user.name=t commit --allow-empty -m "init" -q
  pre=$(git rev-parse HEAD)
  git -c user.email=t@t.test -c user.name=t commit --allow-empty -m "second" -q
  post=$(git rev-parse HEAD)
  run compute_head_unchanged_for_bead_done "$pre" "$post"
  [ "$status" -eq 1 ]
}

@test "compute_head_unchanged_for_bead_done: both empty (pre-first-commit repo) -> unchanged" {
  # Edge case: a repo with no commits has rev-parse HEAD failing; ralph.sh
  # falls back to "" for both pre and post on a stale iter. Empty == empty
  # is unchanged → FAIL routing — same direction as a real same-SHA pair.
  run compute_head_unchanged_for_bead_done "" ""
  [ "$status" -eq 0 ]
}

# --- claude_md_touched_outside_patterns ---------------------------------
#
# Bead agent-template-dvd: the prior `grep -qx CLAUDE.md` proxied the
# touched_claude_md axis on file-name match alone, so every compound bead
# that promoted a model-tagged entry to `## Discovered Patterns` got
# downgraded to MEDIUM even though the gate's rules were unchanged. The
# replacement strips the patterns block from HEAD~1:CLAUDE.md and
# HEAD:CLAUDE.md and compares the rest. These tests cover the bead's
# enumerated edge cases against real temp git repos so the awk regex
# anchors and the file-existence XOR are both pinned.
#
# Helper: write CLAUDE.md content, commit, and stage subsequent edits.
# Uses git -c overrides so the test does not depend on the runner's
# committer identity. Quiet flags suppress git's per-commit chatter.

_dvd_init_repo() {
  cd "$TMPDIR_TEST"
  git init -q
  git config user.email t@t.test
  git config user.name t
}

_dvd_commit_claude_md() {
  printf '%s' "$1" > CLAUDE.md
  git add CLAUDE.md
  git -c user.email=t@t.test -c user.name=t commit -q -m "$2"
}

# A representative CLAUDE.md fixture covering the three section axes the
# downgrade is meant to discriminate: prose, gate-rule body, invariants
# body, and a Discovered Patterns block. Tests mutate one section per
# case so the helper's strip-and-compare can prove which axis flipped.
_dvd_fixture_baseline() {
  cat <<'EOF'
# Project Rules

Some prose between sections.

## Verification Gate

```
bash -n foo.sh && shellcheck foo.sh
```

## Invariants

- Stays under 200 lines.
- No bypassing hooks.

## Discovered Patterns

### First pattern
model: claude-opus-4-7
Body of the first pattern.

### Second pattern
model: claude-opus-4-7
Body of the second pattern.
EOF
}

@test "claude_md_touched_outside_patterns: pattern-only edit returns false (compound-bead happy path)" {
  # The motivating case. A compound bead appends a new ### entry to
  # ## Discovered Patterns; nothing outside the section moves. The strip
  # removes the patterns block from both sides, leaving identical residue
  # — function returns 1 (false), so the touched_claude_md axis stays off
  # and the iteration can earn HIGH on a green gate.
  _dvd_init_repo
  _dvd_fixture_baseline > base.tmp
  _dvd_commit_claude_md "$(cat base.tmp)" "init"
  # Append a third pattern entry inside ## Discovered Patterns.
  cat >> base.tmp <<'EOF'

### Third pattern
model: claude-opus-4-7
A new pattern body.
EOF
  _dvd_commit_claude_md "$(cat base.tmp)" "compound: promote pattern"
  run claude_md_touched_outside_patterns "$TMPDIR_TEST"
  [ "$status" -eq 1 ]
}

@test "claude_md_touched_outside_patterns: ## Invariants edit returns true" {
  # An invariants-body edit is exactly the rule-shifting class the axis
  # exists to flag. The strip preserves the Invariants section in both
  # sides; the diff between them shows up in the comparison and the
  # function returns 0 (true).
  _dvd_init_repo
  _dvd_fixture_baseline > base.tmp
  _dvd_commit_claude_md "$(cat base.tmp)" "init"
  # Mutate one bullet under ## Invariants.
  sed -i.bak 's/200 lines/250 lines/' base.tmp
  rm -f base.tmp.bak
  _dvd_commit_claude_md "$(cat base.tmp)" "invariants: raise size cap"
  run claude_md_touched_outside_patterns "$TMPDIR_TEST"
  [ "$status" -eq 0 ]
}

@test "claude_md_touched_outside_patterns: ## Verification Gate clause edit returns true" {
  # A gate-clause edit redefines the property a green .last-gate-result
  # asserts about the tree — exactly the case the touched_claude_md
  # downgrade is calibrated for. The strip leaves the gate body intact;
  # the per-iter comparison flags the change.
  _dvd_init_repo
  _dvd_fixture_baseline > base.tmp
  _dvd_commit_claude_md "$(cat base.tmp)" "init"
  sed -i.bak 's/bash -n foo.sh/bash -n foo.sh \&\& bash -n bar.sh/' base.tmp
  rm -f base.tmp.bak
  _dvd_commit_claude_md "$(cat base.tmp)" "gate: add bar.sh parse-check"
  run claude_md_touched_outside_patterns "$TMPDIR_TEST"
  [ "$status" -eq 0 ]
}

@test "claude_md_touched_outside_patterns: no CLAUDE.md change returns false" {
  # The HEAD commit touches a file other than CLAUDE.md. HEAD:CLAUDE.md
  # and HEAD~1:CLAUDE.md resolve to identical blobs; stripped, they are
  # identical too. The function must return 1 — a regression that strips
  # asymmetrically (e.g. forgets `next` after the patterns marker) would
  # break this case first.
  _dvd_init_repo
  _dvd_fixture_baseline > base.tmp
  _dvd_commit_claude_md "$(cat base.tmp)" "init"
  printf 'unrelated\n' > other.txt
  git add other.txt
  git -c user.email=t@t.test -c user.name=t commit -q -m "add other.txt"
  run claude_md_touched_outside_patterns "$TMPDIR_TEST"
  [ "$status" -eq 1 ]
}

@test "claude_md_touched_outside_patterns: file added in HEAD returns true" {
  # The file appears for the first time at HEAD: HEAD~1:CLAUDE.md fails
  # the cat-file existence probe, HEAD:CLAUDE.md succeeds. The XOR branch
  # short-circuits to true regardless of whether the new file is mostly
  # patterns — adding the rule file is itself a non-trivial event.
  _dvd_init_repo
  # Seed commit so HEAD~1 exists but does not contain CLAUDE.md.
  printf 'placeholder\n' > seed.txt
  git add seed.txt
  git -c user.email=t@t.test -c user.name=t commit -q -m "seed"
  _dvd_fixture_baseline > base.tmp
  _dvd_commit_claude_md "$(cat base.tmp)" "add CLAUDE.md"
  run claude_md_touched_outside_patterns "$TMPDIR_TEST"
  [ "$status" -eq 0 ]
}

@test "claude_md_touched_outside_patterns: file deleted in HEAD returns true" {
  # The complement of the file-added case: HEAD~1:CLAUDE.md exists,
  # HEAD:CLAUDE.md does not. Same XOR short-circuit on opposite polarity.
  # Deleting the rule file is at least as alarming as editing it.
  _dvd_init_repo
  _dvd_fixture_baseline > base.tmp
  _dvd_commit_claude_md "$(cat base.tmp)" "init"
  git rm -q CLAUDE.md
  git -c user.email=t@t.test -c user.name=t commit -q -m "remove CLAUDE.md"
  run claude_md_touched_outside_patterns "$TMPDIR_TEST"
  [ "$status" -eq 0 ]
}

@test "claude_md_touched_outside_patterns: live repo smoke — boolean shape only" {
  # Smoke against the actual project tree. The verdict for any specific
  # commit changes over time, so this test asserts only the contract
  # surface: the function exits with 0 or 1 (never crashes, never prints
  # to stdout) when called against a real repo with real history.
  run claude_md_touched_outside_patterns "$PROJECT_ROOT"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "claude_md_touched_outside_patterns: pattern-deletion-only edit returns false" {
  # Adversarial complement to the pattern-only happy path: removing a
  # pattern entry (model retirement under § 'Model upgrade drift') is
  # also a patterns-section-only edit and must not downgrade. A
  # regression that compared length-of-file or used a one-sided strip
  # would flip the verdict on deletion while passing on append.
  _dvd_init_repo
  _dvd_fixture_baseline > base.tmp
  _dvd_commit_claude_md "$(cat base.tmp)" "init"
  # Strip the second pattern entry only — leaves first intact.
  awk '
    /^### Second pattern/ { skip=1; next }
    skip && /^### / { skip=0 }
    skip && /^## / { skip=0 }
    !skip
  ' base.tmp > shorter.tmp
  _dvd_commit_claude_md "$(cat shorter.tmp)" "compound: retire pattern"
  run claude_md_touched_outside_patterns "$TMPDIR_TEST"
  [ "$status" -eq 1 ]
}

@test "claude_md_touched_outside_patterns: edit straddling patterns boundary returns true" {
  # A mixed edit — one line inside ## Discovered Patterns and one line
  # outside — must trip the downgrade. The strip keeps the outside line
  # in the comparison, so even when the patterns delta is the loudest
  # part of the diff the residue still differs. Pins against a regression
  # that shorts to false whenever any pattern changed.
  _dvd_init_repo
  _dvd_fixture_baseline > base.tmp
  _dvd_commit_claude_md "$(cat base.tmp)" "init"
  sed -i.bak 's/Some prose between sections./Some prose between sections, edited./' base.tmp
  cat >> base.tmp <<'EOF'

### Fourth pattern
model: claude-opus-4-7
Body of the fourth pattern.
EOF
  rm -f base.tmp.bak
  _dvd_commit_claude_md "$(cat base.tmp)" "mixed: prose + pattern"
  run claude_md_touched_outside_patterns "$TMPDIR_TEST"
  [ "$status" -eq 0 ]
}

@test "ralph.sh stale-HEAD path forces gate_result=FAIL and writes FAIL to .last-gate-result" {
  # Integration test: extract ralph.sh's gate-result block (from the
  # `_RALPH_GATE_RESULT="skipped"` assignment through the closing outer `fi`)
  # and eval it under variable state that reproduces the stale-HEAD
  # condition. Must short-circuit run_gate (so a green gate cannot mask the
  # bug) and must write FAIL to .last-gate-result so the pre-push hook also
  # rejects the push. Both properties are pinned: a regression that drops
  # the stale-head branch fails the second assertion; a regression that
  # lets the gate run anyway fails the first (the stub run_gate returns
  # PASS, which would clobber FAIL).
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  block=$(awk '
    /^[[:space:]]*_RALPH_GATE_RESULT="skipped"$/ { capture=1 }
    /^[[:space:]]*# --- Confidence routing/ { exit }
    capture { print }
  ' "$ralph")
  [ -n "$block" ]

  # Stub run_gate so a regression that lets the gate run anyway is caught:
  # if the stale-HEAD branch is dropped, eval falls through to run_gate,
  # which returns PASS — opposite of the expected FAIL.
  run_gate() { printf 'PASS\n' > "$2"; return 0; }

  _RALPH_PROJECT_ROOT="$TMPDIR_TEST"
  _RALPH_GATE_CMD="true"
  _RALPH_BEAD_DONE=true
  _RALPH_STALE_HEAD=true

  eval "$block"

  [ "$_RALPH_GATE_RESULT" = "FAIL" ]
  [ -f "$TMPDIR_TEST/.last-gate-result" ]
  [ "$(cat "$TMPDIR_TEST/.last-gate-result")" = "FAIL" ]
}

@test "ralph.sh non-stale BEAD_DONE path runs the gate normally" {
  # Complement to the above: when _RALPH_STALE_HEAD=false on BEAD_DONE,
  # the gate runs as before. Pins that the stale-HEAD branch did not
  # accidentally swallow the normal path — a regression of the form
  # `if [[ "$_RALPH_STALE_HEAD" != "false" ]]` (typo, polarity flip)
  # would force every BEAD_DONE to FAIL, not just stale ones.
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  block=$(awk '
    /^[[:space:]]*_RALPH_GATE_RESULT="skipped"$/ { capture=1 }
    /^[[:space:]]*# --- Confidence routing/ { exit }
    capture { print }
  ' "$ralph")
  [ -n "$block" ]

  run_gate() { printf 'PASS\n' > "$2"; return 0; }

  _RALPH_PROJECT_ROOT="$TMPDIR_TEST"
  _RALPH_GATE_CMD="true"
  _RALPH_BEAD_DONE=true
  _RALPH_STALE_HEAD=false

  eval "$block"

  [ "$_RALPH_GATE_RESULT" = "PASS" ]
  [ "$(cat "$TMPDIR_TEST/.last-gate-result")" = "PASS" ]
}

@test "ralph.sh confidence.log carries stale_head=true on stale-HEAD iter" {
  # The audit-trail half of the contract: the confidence.log line must
  # carry `stale_head=true` so a future grep can find these iters without
  # cross-correlating against git log timestamps. Extracts the auto-land
  # branch's log echo and eval's it under stale-HEAD state. The pre-fix
  # log line had no stale_head field at all; the fix adds it through the
  # _RALPH_STALE_HEAD_FIELD interpolation. Both branches (HIGH-and-auto-land
  # and confidence=NONE) carry the field — this test pins the auto-land one;
  # the next test pins the NONE branch.
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  log_line=$(awk '/^[[:space:]]*echo "\[\$\(date.*bead_done=\$_RALPH_BEAD_DONE.*auto_land=\$_RALPH_AUTO_LAND/ { print; exit }' "$ralph")
  [ -n "$log_line" ]

  _RALPH_I=1
  _RALPH_BEAD_ID="agent-template-xyz"
  _RALPH_BEAD_DONE=true
  _RALPH_CONFIDENCE="LOW"
  _RALPH_POLICY="all"
  _RALPH_AUTO_LAND="false"
  _RALPH_GATE_RESULT="FAIL"
  _RALPH_STALE_HEAD_FIELD=" stale_head=true"
  _RALPH_CONFIDENCE_LOG="$TMPDIR_TEST/confidence.log"
  : > "$_RALPH_CONFIDENCE_LOG"

  eval "$log_line"

  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" == *"stale_head=true"* ]] || { echo "Got: $emitted"; return 1; }
}

@test "ralph.sh confidence.log omits stale_head field on healthy iter" {
  # Complement: healthy iters do not pollute the log with stale_head=false.
  # A future audit grepping `stale_head=true` would otherwise still match
  # negated forms in less-careful greps; keeping the field absent on
  # healthy iters means the presence of the substring is itself the signal.
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  log_line=$(awk '/^[[:space:]]*echo "\[\$\(date.*bead_done=\$_RALPH_BEAD_DONE.*auto_land=\$_RALPH_AUTO_LAND/ { print; exit }' "$ralph")
  [ -n "$log_line" ]

  _RALPH_I=1
  _RALPH_BEAD_ID="agent-template-xyz"
  _RALPH_BEAD_DONE=true
  _RALPH_CONFIDENCE="HIGH"
  _RALPH_POLICY="all"
  _RALPH_AUTO_LAND="true"
  _RALPH_GATE_RESULT="PASS"
  _RALPH_STALE_HEAD_FIELD=""
  _RALPH_CONFIDENCE_LOG="$TMPDIR_TEST/confidence.log"
  : > "$_RALPH_CONFIDENCE_LOG"

  eval "$log_line"

  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" != *"stale_head"* ]] || { echo "Got: $emitted"; return 1; }
}

# --- LOOP_SATURATION emission ------------------------------------------
#
# loop_saturation is the runtime detector for the runaway feedback loop
# documented in docs/upstream-harness-improvements.md § 2026-04-29: a
# fixed point of self-tightening reviews where consecutive `Phase N
# follow-up:` beads close without any `Phase N impl:` or `integration-`
# bead landing in the window. The compute_confidence axis downgrades the
# verdict; the LOOP_SATURATION confidence.log line is the operator-facing
# audit trail. Both must fire from the same trigger (ratio in [0,1] and
# > 0.6) — splitting them would let one drift without the other.

@test "ralph.sh confidence.log emits LOOP_SATURATION line when followup_ratio fires" {
  # Extract the emit-block from ralph.sh and eval it with the ratio above
  # the cut. The whole if-block (predicate + echo) is evaluated so a
  # regression that loosens the predicate to `>=` or drops the range
  # check would surface here.
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  emit_block=$(awk '
    /^[[:space:]]*if \[\[ "\$\(awk -v r="\$_RALPH_FOLLOWUP_RATIO/ { in_blk=1 }
    in_blk { print }
    in_blk && /^[[:space:]]*fi[[:space:]]*$/ { exit }
  ' "$ralph")
  [ -n "$emit_block" ]

  _RALPH_I=1
  _RALPH_BEAD_ID="agent-template-xyz"
  _RALPH_FOLLOWUP_RATIO=0.8
  _RALPH_FOLLOWUP_NUMER=4
  _RALPH_FOLLOWUP_DENOM=5
  _RALPH_CONFIDENCE_LOG="$TMPDIR_TEST/confidence.log"
  : > "$_RALPH_CONFIDENCE_LOG"

  eval "$emit_block"

  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" == *"LOOP_SATURATION"* ]] || { echo "Got: $emitted"; return 1; }
  [[ "$emitted" == *"followup_ratio=4/5"* ]] || { echo "Got: $emitted"; return 1; }
  [[ "$emitted" == *"bead=agent-template-xyz"* ]] || { echo "Got: $emitted"; return 1; }
}

@test "ralph.sh confidence.log omits LOOP_SATURATION line when followup_ratio is at/below cut" {
  # Complement: ratio at or below the 0.6 cut must not fire. Pinning this
  # silence is what lets a future audit trust the LOOP_SATURATION substring
  # as the signal — a regression that flips `>` to `>=` would surface here
  # (0.6 would start firing).
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  emit_block=$(awk '
    /^[[:space:]]*if \[\[ "\$\(awk -v r="\$_RALPH_FOLLOWUP_RATIO/ { in_blk=1 }
    in_blk { print }
    in_blk && /^[[:space:]]*fi[[:space:]]*$/ { exit }
  ' "$ralph")
  [ -n "$emit_block" ]

  _RALPH_I=1
  _RALPH_BEAD_ID="agent-template-xyz"
  _RALPH_FOLLOWUP_RATIO=0.6
  _RALPH_FOLLOWUP_NUMER=3
  _RALPH_FOLLOWUP_DENOM=5
  _RALPH_CONFIDENCE_LOG="$TMPDIR_TEST/confidence.log"
  : > "$_RALPH_CONFIDENCE_LOG"

  eval "$emit_block"

  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" != *"LOOP_SATURATION"* ]] || { echo "Got: $emitted"; return 1; }
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
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"

  # Extract the BEAD_DONE log line from the auto-land branch. Identified by
  # its trailing fields (`auto_land=$_RALPH_AUTO_LAND gate_result=...`),
  # which are unique to this line in ralph.sh.
  log_line=$(awk '/^[[:space:]]*echo "\[\$\(date.*bead_done=\$_RALPH_BEAD_DONE.*auto_land=\$_RALPH_AUTO_LAND/ { print; exit }' "$ralph")
  [ -n "$log_line" ]

  # Reproduce the bug condition: no in-progress bead at iter start, fresh
  # bead picked up via _ralph_bead_ready. Pre-fix this would emit
  # `bead=unknown`; post-fix it emits the picked-up id.
  _RALPH_I=1
  _RALPH_ACTIVE_BEAD=""
  _RALPH_BEAD_ID="agent-template-xyz"
  _RALPH_BEAD_DONE=true
  _RALPH_CONFIDENCE="HIGH"
  _RALPH_POLICY="all"
  _RALPH_AUTO_LAND="true"
  _RALPH_GATE_RESULT="PASS"
  _RALPH_CONFIDENCE_LOG="$TMPDIR_TEST/confidence.log"
  : > "$_RALPH_CONFIDENCE_LOG"

  eval "$log_line"

  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" == *"bead=agent-template-xyz"* ]] || { echo "Got: $emitted"; return 1; }
  [[ "$emitted" != *"bead=unknown"* ]] || { echo "Got: $emitted"; return 1; }
}

@test "ralph.sh confidence=NONE log line uses the picked-up bead id when iter started clean" {
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"

  # Extract the confidence=NONE branch log line (BEAD_DONE seen but no
  # confidence verdict — e.g., a bead_done=false path that still wants to
  # log the iter outcome). Identified by `confidence=NONE`.
  log_line=$(awk '/^[[:space:]]*echo "\[\$\(date.*bead_done=\$_RALPH_BEAD_DONE.*confidence=NONE/ { print; exit }' "$ralph")
  [ -n "$log_line" ]

  _RALPH_I=1
  _RALPH_ACTIVE_BEAD=""
  _RALPH_BEAD_ID="agent-template-xyz"
  _RALPH_BEAD_DONE=true
  _RALPH_GATE_RESULT="PASS"
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
# via awk and eval them in isolation. Same shape used by the existing
# stale-HEAD / log-emit tests above.

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

# --- ralph.sh confidence.log fields per branch -------------------------
#
# Five log echo points — BLOCKED, REWORK, ESCALATION, BEAD_DONE-with-
# confidence, BEAD_DONE-without-confidence — each gain bead_type=$type and
# title="<sanitized>". The two BEAD_DONE branches additionally gain
# completed="<sanitized>". Tests extract the live source line and eval it
# so a regression to the old field set surfaces here even if the line's
# shape moves.

@test "ralph.sh BLOCKED log line carries bead_type and sanitized title" {
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  log_line=$(awk '/^[[:space:]]*echo "\[\$\(date.*BLOCKED bead=/ { print; exit }' "$ralph")
  [ -n "$log_line" ]

  _ralph_sanitize_log_field() { printf '%s' "$1"; }
  _RALPH_I=1
  _RALPH_ACTIVE_BEAD="agent-template-xyz"
  _RALPH_BEAD_TYPE="impl"
  _RALPH_BEAD_TITLE="impl: do the thing"
  _RALPH_BLOCKED_REASON="missing dep"
  _RALPH_CONFIDENCE_LOG="$TMPDIR_TEST/confidence.log"
  : > "$_RALPH_CONFIDENCE_LOG"
  eval "$log_line"
  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" == *"bead_type=impl"* ]] || { echo "Got: $emitted"; return 1; }
  [[ "$emitted" == *'title="impl: do the thing"'* ]] || { echo "Got: $emitted"; return 1; }
}

@test "ralph.sh REWORK log line carries bead_type and sanitized title" {
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  log_line=$(awk '/^[[:space:]]*echo "\[\$\(date.*REWORK bead=/ { print; exit }' "$ralph")
  [ -n "$log_line" ]

  _ralph_sanitize_log_field() { printf '%s' "$1"; }
  _RALPH_I=1
  _RALPH_ACTIVE_BEAD="agent-template-xyz"
  _RALPH_BEAD_TYPE="review"
  _RALPH_BEAD_TITLE="review: audit foo"
  _RALPH_REWORK_REASON="prereq incomplete"
  _RALPH_CONFIDENCE_LOG="$TMPDIR_TEST/confidence.log"
  : > "$_RALPH_CONFIDENCE_LOG"
  eval "$log_line"
  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" == *"bead_type=review"* ]] || { echo "Got: $emitted"; return 1; }
  [[ "$emitted" == *'title="review: audit foo"'* ]] || { echo "Got: $emitted"; return 1; }
}

@test "ralph.sh ESCALATION log line carries bead_type and sanitized title" {
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  log_line=$(awk '/^[[:space:]]*echo "\[\$\(date.*ESCALATION bead=/ { print; exit }' "$ralph")
  [ -n "$log_line" ]

  _ralph_sanitize_log_field() { printf '%s' "$1"; }
  _RALPH_I=1
  _RALPH_FAILED_BEAD="agent-template-xyz"
  _RALPH_BEAD_TYPE="impl"
  _RALPH_BEAD_TITLE="impl: do the thing"
  _RALPH_FAIL_COUNT=3
  _RALPH_CONFIDENCE_LOG="$TMPDIR_TEST/confidence.log"
  : > "$_RALPH_CONFIDENCE_LOG"
  eval "$log_line"
  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" == *"bead_type=impl"* ]] || { echo "Got: $emitted"; return 1; }
  [[ "$emitted" == *'title="impl: do the thing"'* ]] || { echo "Got: $emitted"; return 1; }
}

@test "ralph.sh BEAD_DONE auto-land log line carries bead_type, title, and completed" {
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  log_line=$(awk '/^[[:space:]]*echo "\[\$\(date.*bead_done=\$_RALPH_BEAD_DONE.*auto_land=\$_RALPH_AUTO_LAND/ { print; exit }' "$ralph")
  [ -n "$log_line" ]

  _ralph_sanitize_log_field() { printf '%s' "$1"; }
  _RALPH_I=1
  _RALPH_BEAD_ID="agent-template-xyz"
  _RALPH_BEAD_TYPE="impl"
  _RALPH_BEAD_TITLE="impl: do the thing"
  _RALPH_BEAD_DONE=true
  _RALPH_CONFIDENCE="HIGH"
  _RALPH_POLICY="all"
  _RALPH_AUTO_LAND="true"
  _RALPH_GATE_RESULT="PASS"
  _RALPH_STALE_HEAD_FIELD=""
  _RALPH_COMPLETED_SUMMARY="feat: [agent-template-xyz] - did the thing"
  _RALPH_CONFIDENCE_LOG="$TMPDIR_TEST/confidence.log"
  : > "$_RALPH_CONFIDENCE_LOG"
  eval "$log_line"
  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" == *"bead_type=impl"* ]] || { echo "Got: $emitted"; return 1; }
  [[ "$emitted" == *'title="impl: do the thing"'* ]] || { echo "Got: $emitted"; return 1; }
  [[ "$emitted" == *'completed="feat: [agent-template-xyz] - did the thing"'* ]] || { echo "Got: $emitted"; return 1; }
}

@test "ralph.sh BEAD_DONE confidence=NONE log line carries bead_type, title, and completed" {
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  log_line=$(awk '/^[[:space:]]*echo "\[\$\(date.*bead_done=\$_RALPH_BEAD_DONE.*confidence=NONE/ { print; exit }' "$ralph")
  [ -n "$log_line" ]

  _ralph_sanitize_log_field() { printf '%s' "$1"; }
  _RALPH_I=1
  _RALPH_BEAD_ID="agent-template-xyz"
  _RALPH_BEAD_TYPE="impl"
  _RALPH_BEAD_TITLE="impl: do the thing"
  _RALPH_BEAD_DONE=true
  _RALPH_GATE_RESULT="PASS"
  _RALPH_STALE_HEAD_FIELD=""
  _RALPH_COMPLETED_SUMMARY="feat: [agent-template-xyz] - did the thing"
  _RALPH_CONFIDENCE_LOG="$TMPDIR_TEST/confidence.log"
  : > "$_RALPH_CONFIDENCE_LOG"
  eval "$log_line"
  emitted=$(cat "$_RALPH_CONFIDENCE_LOG")
  [[ "$emitted" == *"bead_type=impl"* ]] || { echo "Got: $emitted"; return 1; }
  [[ "$emitted" == *'title="impl: do the thing"'* ]] || { echo "Got: $emitted"; return 1; }
  [[ "$emitted" == *'completed="feat: [agent-template-xyz] - did the thing"'* ]] || { echo "Got: $emitted"; return 1; }
}

@test "archive_schema_check still extracts bead id when bead_type field is also present" {
  # Backward-compat invariant: archive_schema_check uses `grep -oE 'bead=[^ ]+'`
  # to extract the bead id from confidence.log. The new `bead_type=<word>`
  # field starts with a different token (`bead_type=`, not `bead=`) so the
  # regex must not match it. A regression that drops the trailing `=` from
  # the regex (e.g. `bead[^ ]+`) would silently match `bead_type=...` and
  # try to look up `type=impl` in archive.txt — which would always fail.
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/hooks/parsers.sh"
  cd "$TMPDIR_TEST"
  cat > confidence.log <<'EOF'
[2026-04-30T12:00:00] iter=1 bead=agent-template-xyz bead_type=impl bead_done=true confidence=HIGH policy=high auto_land=true gate_result=PASS title="x" completed="y"
EOF
  cat > archive.txt <<'EOF'
## 2026-04-30 12:00 - agent-template-xyz
- Type: impl
EOF
  run archive_schema_check archive.txt confidence.log
  [ "$status" -eq 0 ] || { echo "out: $output"; return 1; }
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
  # stale type/title/desc/summary/governance-json from a prior run into the next.
  _load_ralph_helpers
  _RALPH_HAD_NOUNSET=0
  _RALPH_BEAD_TYPE="impl"
  _RALPH_BEAD_DESCRIPTION="X"
  _RALPH_COMPLETED_SUMMARY="Y"
  _RALPH_GOVERNANCE_JSON='[]'
  _ralph_cleanup
  [ -z "${_RALPH_BEAD_TYPE:-}" ]
  [ -z "${_RALPH_BEAD_DESCRIPTION:-}" ]
  [ -z "${_RALPH_COMPLETED_SUMMARY:-}" ]
  [ -z "${_RALPH_GOVERNANCE_JSON:-}" ]
}

# --- governance_bead_max_age_days + _ralph_surface_stale_governance ----
#
# Bead agent-template-ebh: governance beads (Observe / Audit / Decide /
# Triage / Review the loop) sit in `bd ready` indefinitely because they
# get the same priority as module work. The fix surfaces them above the
# iter banner at >3d and forces compute_confidence's verdict to LOW
# at >7d. Two helpers, one shared bd-list snapshot:
#   - governance_bead_max_age_days (lib.sh)  : pure predicate, takes JSON.
#   - _ralph_surface_stale_governance (ralph.sh) : pure surfacing helper.
# The 7d boundary is bracketed at 7d (stays) and 8d (forces) so a future
# `>` vs `>=` flip in the predicate is caught mechanically.

# Build an ISO-8601 timestamp for `now - days*86400` seconds. Uses
# `date -ur SECONDS +FORMAT` which is portable across BSD (macOS) and
# GNU date — `-r` reads epoch seconds, `-u` outputs UTC, the explicit
# `+00:00` suffix avoids `date`'s `+%z` BSD/GNU-formatting drift.
_iso_n_days_ago() {
  local now_epoch="$1"
  local days="$2"
  date -ur "$(( now_epoch - days * 86400 ))" +%Y-%m-%dT%H:%M:%S+00:00
}

@test "governance_bead_max_age_days: empty input returns 1 (no governance is benign)" {
  # Defensive: a bd-call failure surfaces as empty input. A truthy return
  # would force LOW on every iter where bd is unreachable — false-positive
  # confidence downgrade. Fail-closed in the other direction here.
  run governance_bead_max_age_days ""
  [ "$status" -eq 1 ]
}

@test "governance_bead_max_age_days: empty array returns 1 (no matching bead)" {
  # No open beads at all → no governance is stale.
  run governance_bead_max_age_days "[]"
  [ "$status" -eq 1 ]
}

@test "governance_bead_max_age_days: non-governance bead (Phase 3 impl:) is ignored" {
  # The whole point of the title regex is to filter module work out.
  # A Phase 3 impl: bead at 30 days old must NOT trigger the override.
  local now=1745000000
  local ts; ts=$(_iso_n_days_ago "$now" 30)
  local json
  json='[{"id":"agent-template-aaa","title":"Phase 3 impl: do the thing","created_at":"'$ts'"}]'
  run governance_bead_max_age_days "$json" "$now"
  [ "$status" -eq 1 ]
}

@test "governance_bead_max_age_days: governance bead at exactly 7 days returns 1 (≤7d boundary stays)" {
  # Bracket-low side of the cut. 7d exactly is age=7; the rule is strict
  # >7, so this case stays at the prevailing confidence. Pinning the
  # boundary so a future `>` vs `>=` flip is caught mechanically (paired
  # with the 8d test below).
  local now=1745000000
  local ts; ts=$(_iso_n_days_ago "$now" 7)
  local json
  json='[{"id":"agent-template-uq6","title":"Observe ralph loop","created_at":"'$ts'"}]'
  run governance_bead_max_age_days "$json" "$now"
  [ "$status" -eq 1 ]
}

@test "governance_bead_max_age_days: governance bead at exactly 8 days returns 0 (>7d forces)" {
  # Bracket-high side of the cut. 8d exactly is age=8 > 7; force LOW.
  local now=1745000000
  local ts; ts=$(_iso_n_days_ago "$now" 8)
  local json
  json='[{"id":"agent-template-uq6","title":"Observe ralph loop","created_at":"'$ts'"}]'
  run governance_bead_max_age_days "$json" "$now"
  [ "$status" -eq 0 ]
}

@test "governance_bead_max_age_days: matches every governance title prefix at >7d" {
  # The regex is GOVERNANCE_TITLE_REGEX. Any title that starts with one
  # of Observe / Audit / Decide / Triage / Review the loop is a governance
  # bead. A regression that drops one of the prefixes silently re-opens
  # that class of audit instruction to indefinite staleness.
  local now=1745000000
  local ts; ts=$(_iso_n_days_ago "$now" 8)
  for prefix in "Observe ralph loop" "Audit register integrity" "Decide on research-phase split" "Triage bead-flow staleness" "Review the loop for invariant drift"; do
    local json
    json='[{"id":"agent-template-xxx","title":"'$prefix'","created_at":"'$ts'"}]'
    run governance_bead_max_age_days "$json" "$now"
    [ "$status" -eq 0 ] || { echo "Failed prefix: $prefix" >&2; return 1; }
  done
}

@test "governance_bead_max_age_days: oldest of multiple matching beads decides" {
  # Mix one young (3d) and one old (10d) governance bead with one young
  # non-governance bead. Predicate must pick the oldest matching bead,
  # not the newest one or a non-matching one. A bug that read .[0] without
  # sorting would give different verdicts depending on bd's list order.
  local now=1745000000
  local young; young=$(_iso_n_days_ago "$now" 3)
  local old; old=$(_iso_n_days_ago "$now" 10)
  local json
  json='[
    {"id":"a","title":"Audit recent","created_at":"'$young'"},
    {"id":"b","title":"Phase 3 impl: foo","created_at":"'$young'"},
    {"id":"c","title":"Observe old","created_at":"'$old'"}
  ]'
  run governance_bead_max_age_days "$json" "$now"
  [ "$status" -eq 0 ]
}

@test "_ralph_surface_stale_governance: prints under header for >3d matching bead" {
  # The visibility half: the operator sees the stale bead before the
  # agent claims its next module bead. Output shape is
  # `⚠ Stale governance:` header followed by indented `id (Nd) title`.
  _load_ralph_helpers
  source "$PROJECT_ROOT/scripts/ralph/lib.sh"
  local now; now=$(date +%s)
  local ts; ts=$(_iso_n_days_ago "$now" 5)
  local json
  json='[{"id":"agent-template-uq6","title":"Observe ralph loop","created_at":"'$ts'"}]'
  run _ralph_surface_stale_governance "$json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ Stale governance:"* ]] || { echo "Got: $output" >&2; return 1; }
  [[ "$output" == *"agent-template-uq6 (5d) Observe ralph loop"* ]] || { echo "Got: $output" >&2; return 1; }
}

@test "_ralph_surface_stale_governance: silent on ≤3d matching bead" {
  # Surfacing kicks in at >3d (operator's first warning), separate from
  # the >7d hard force-LOW rule. A 2d-old governance bead is recent and
  # not yet stale; printing it would dilute the signal.
  _load_ralph_helpers
  source "$PROJECT_ROOT/scripts/ralph/lib.sh"
  local now; now=$(date +%s)
  local ts; ts=$(_iso_n_days_ago "$now" 2)
  local json
  json='[{"id":"agent-template-xxx","title":"Audit recent","created_at":"'$ts'"}]'
  run _ralph_surface_stale_governance "$json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_ralph_surface_stale_governance: silent on non-matching bead at >3d" {
  # Phase 3 impl: bead at 30 days is not governance. Visibility surface
  # must not list module work — that's what the existing iter banner is for.
  _load_ralph_helpers
  source "$PROJECT_ROOT/scripts/ralph/lib.sh"
  local now; now=$(date +%s)
  local ts; ts=$(_iso_n_days_ago "$now" 30)
  local json
  json='[{"id":"agent-template-yyy","title":"Phase 3 impl: do the thing","created_at":"'$ts'"}]'
  run _ralph_surface_stale_governance "$json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_ralph_surface_stale_governance: silent on empty input (bd unreachable)" {
  # Best-effort visibility: bd-call failure produces empty input, helper
  # silently no-ops. A spurious header printed on every empty-input call
  # would train the operator to ignore the warning siren.
  _load_ralph_helpers
  source "$PROJECT_ROOT/scripts/ralph/lib.sh"
  run _ralph_surface_stale_governance ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ralph.sh forces _RALPH_CONFIDENCE=LOW when governance bead predicate is truthy" {
  # Integration test: extract the post-compute_confidence override block
  # from ralph.sh and eval it under state where compute_confidence has
  # just returned HIGH and the governance JSON carries an 8d-old Observe
  # bead. A regression that deletes the override fails this test (the
  # block disappears or no longer references the predicate).
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  block=$(awk '
    /^[[:space:]]*if governance_bead_max_age_days/ { capture=1 }
    capture { print }
    capture && /^[[:space:]]*fi[[:space:]]*$/ { exit }
  ' "$ralph")
  [ -n "$block" ] || { echo "override block not found in ralph.sh" >&2; return 1; }

  source "$PROJECT_ROOT/scripts/ralph/lib.sh"

  local now; now=$(date +%s)
  local ts; ts=$(_iso_n_days_ago "$now" 8)
  _RALPH_GOVERNANCE_JSON='[{"id":"agent-template-uq6","title":"Observe ralph loop","created_at":"'$ts'"}]'
  _RALPH_CONFIDENCE="HIGH"

  eval "$block"
  [ "$_RALPH_CONFIDENCE" = "LOW" ]
}

@test "ralph.sh leaves _RALPH_CONFIDENCE unchanged when governance predicate is falsy" {
  # Complement to the force-LOW test: a polarity flip (e.g., dropping the
  # `if`, or wiring to a negated predicate) would override every BEAD_DONE
  # iter to LOW regardless of governance state. With this test in place
  # the regression surfaces as "every iter is LOW now."
  ralph="$PROJECT_ROOT/scripts/ralph/ralph.sh"
  block=$(awk '
    /^[[:space:]]*if governance_bead_max_age_days/ { capture=1 }
    capture { print }
    capture && /^[[:space:]]*fi[[:space:]]*$/ { exit }
  ' "$ralph")
  [ -n "$block" ]

  source "$PROJECT_ROOT/scripts/ralph/lib.sh"

  _RALPH_GOVERNANCE_JSON='[]'
  _RALPH_CONFIDENCE="HIGH"

  eval "$block"
  [ "$_RALPH_CONFIDENCE" = "HIGH" ]
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
