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
