## Codebase Patterns

<!--
Pattern seeds captured during iteration. Compound beads promote durable
cross-cutting patterns to CLAUDE.md `## Discovered Patterns` and review-
specific ones to docs/skills/review-rubric.md. Narrow ones stay here as a
scratchpad until they earn a durable home (or are retired).
-->

### Extracting a fenced-code-block convention from CLAUDE.md in awk

Use an `in_section` flag that flips on when the target `##` heading is matched
and off when the next `##` heading appears; a separate `in_fence` flag toggles
on every triple-backtick line. Only print lines where both flags are set.
Anchor the heading match with `[[:space:]]*$` so it doesn't match longer
headings that share the prefix. Pattern used by `.git/hooks/pre-push` to
extract the `## Verification Gate` body from `CLAUDE.md`.

### Env-var sentinel to prevent test-invokes-gate-invokes-test recursion

When the verification gate runs a test runner whose own suite contains a
"gate passes against the current repo" sanity test, the test will recurse
forever unless it skips when re-entered. Export a sentinel env var (e.g.
`_BATS_GATE_REENTRY=1`) before running the gate from inside the sanity
test; at the top of the test, `skip` if the sentinel is already set. The
variable propagates to child processes naturally, so the nested bats
invocation started by the gate sees the flag and bails out of just the
one recursive test — the rest of the suite still runs in the nested call.
This lets the gate keep invoking the full test suite (parser regressions
surface mechanically) without infinite loops.
