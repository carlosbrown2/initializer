## Codebase Patterns

<!-- Add project-specific patterns here as they are discovered during implementation -->

### Extracting a fenced-code-block convention from CLAUDE.md in awk

Use an `in_section` flag that flips on when the target `##` heading is matched
and off when the next `##` heading appears; a separate `in_fence` flag toggles
on every triple-backtick line. Only print lines where both flags are set.
Anchor the heading match with `[[:space:]]*$` so it doesn't match longer
headings that share the prefix. Pattern used by `.git/hooks/pre-push` to
extract the `## Verification Gate` body from `CLAUDE.md`.

### Promoting a decision-register row from ritual-bounded to bounded

When an audit bead lands the enforcement mechanism a row was pending, update
three things in the same commit: (1) the Enforcement cell — name the file
that does the enforcement, because the decision-register integrity hook
validates that any path-shaped token in the register exists on disk; (2) the
Status cell — flip to `bounded`; (3) the "Pending promotions" section below
the table — remove the matching bullet. Missing any of the three leaves the
register internally inconsistent.

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

### One implementation, one library: hook script sources the library the tests import

When a pre-commit hook and a test suite both need the same parser/validator
logic, don't duplicate the logic — put it in a sourceable library
(`scripts/hooks/parsers.sh`) and have both the generated hook and the
bats suite `source` it. The generated hook fails closed if the library is
missing, so "forgot to re-run install.sh after editing parsers.sh" is a hard
error instead of a silent drift. Pairs with smoke tests: the bats suite
should run each parser against the real committed registers so that a
register edit which no longer parses is caught before a human hits
pre-commit.
