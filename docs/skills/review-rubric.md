# Initializer Template Review Severity Rubric

## When to load

Load this skill at the start of every **review** bead. Every finding in a review artifact (`docs/reviews/<bead-id>.md`) must cite a clause from this rubric. The pre-commit review-artifact validator rejects review files that don't reference this rubric.

This rubric exists to **bound the "review verdict" decision point** in `docs/decision-register.md`. Without it, severity classification is the model's intuition — and two runs of the same review can produce different P1 sets. With it, severity is anchored to a checked-in standard, and the review's variance is funneled into the rubric's clauses.

The Initializer Template uses this rubric for its own review beads, with one project-specific clause added (`P1.hook-bypass`) reflecting CLAUDE.md's "no hook is ever bypassed" invariant. Projects bootstrapped from this template should rename the header to a project-named one and add their own domain-specific clauses (security-critical projects may add new categories; data-science projects may emphasize statistical correctness, etc.). Whatever clauses you add, the contract is that **every finding in every review cites a specific clause by name**. The pre-commit rubric-edit guard rejects commits while the rubric still carries its original "starter" disclaimer.

---

## Severity definitions

### P1 — Must fix before merge

A finding is P1 if **any** of the following clauses applies:

- **P1.correctness** — The implementation produces a wrong result for an input the spec covers. Includes off-by-one errors, wrong operator, swapped arguments, missing edge case handling for documented inputs.
- **P1.contract-violation** — The code violates a precondition, postcondition, type signature, or invariant declared elsewhere in the codebase. The contract was checked in; the new code doesn't honor it.
- **P1.register-gap** — The implementation introduces a failure mode not covered by `docs/failure-modes.md`, or the new row's Status is not `covered` / `proven-impossible` / `out-of-scope`. (The failure-mode register hook should have caught this; if it didn't, the hook is the real bug — file it as P1 too.)
- **P1.decision-gap** — The implementation introduces a new decision point (a new place agent variance can enter) that has no row in `docs/decision-register.md`.
- **P1.security** — The code introduces a known anti-pattern (hardcoded secret, injection vector, unsafe deserialization, missing auth check, broken access control). Cite the specific anti-pattern.
- **P1.data-loss** — The code can lose, corrupt, or silently drop data. Includes torn writes, lost updates, partial commits visible to readers, missing transaction boundaries.
- **P1.scope-violation** — The diff touches files outside the bead's declared `.current-bead-scope` (the scope hook should have caught this; if it didn't, that's P1 too).
- **P1.gate-bypass** — The verification gate was reported as green but the code path the bead introduced isn't actually exercised by the gate. The "done" claim isn't backed by the gate.
- **P1.test-tautology** — A test asserts something that is always true (e.g., `assert result == result`, `assert isinstance(x, type(x))`) or asserts on the mock instead of the system under test.
- **P1.flaky-test** — A test passes or fails depending on system state, run order, wall clock, or random sampling. Flaky tests destroy the verification gate's truth value, which is the foundation of every other contract.
- **P1.hook-bypass** — Code, scripts, docs, or workflows use `--no-verify`, edit `.git/hooks/` directly, or otherwise circumvent an installed hook (project-specific clause for the Initializer Template). CLAUDE.md's invariant: no hook is ever bypassed; if a hook is wrong, fix the hook in a separate bead. Includes hook generators that silently skip checks under conditions not declared in their contract.

### P2 — Should fix soon (file as a new bead)

A finding is P2 if **any** of the following clauses applies:

- **P2.weak-test** — The test exists and passes, but doesn't actually constrain the implementation tightly. A common case: the test would still pass if the implementation were replaced with a constant, or an `if False`.
- **P2.duplicated-logic** — The implementation duplicates logic that already exists elsewhere in the codebase. The duplication will drift.
- **P2.poor-naming** — A function, variable, or module name actively misleads about what it does. Not "could be more elegant" — must be misleading.
- **P2.over-abstraction** — The code introduces an interface, factory, registry, or layer that has only one implementation and no near-term reason to grow. Speculative generality.
- **P2.under-abstraction** — A pattern is repeated 3+ times with the same shape, where extracting a helper would clearly remove duplication. (Two repetitions is fine; three+ usually warrants extraction.)
- **P2.missing-error-handling** — The code calls an operation that can fail, and the failure mode isn't in the failure-mode register and isn't handled by the surrounding code.
- **P2.dependency-bloat** — The bead introduces a new dependency where an existing one (or a small amount of inline code) would suffice.

### P3 — Nice to fix (note in archive.txt)

A finding is P3 if **any** of the following clauses applies:

- **P3.style** — Inconsistency with project conventions on naming, formatting, import order, etc. — anything not caught by the linter.
- **P3.docstring-drift** — A docstring or comment contradicts the code it describes (or was correct but is now stale).
- **P3.minor-simplification** — A small simplification that doesn't reduce coupling or improve safety, but reads more cleanly.
- **P3.test-clarity** — A test that works but would be clearer with better fixture names, helper extraction, or assertion messages.

---

## How to cite a clause in a review artifact

Each finding in `docs/reviews/<bead-id>.md` must include the clause name. Example:

```markdown
### Findings

**P1.correctness** — `src/auth/login.py:42` returns `True` on lockout, should return `False`. The `is_locked()` check is inverted.

**P1.register-gap** — `src/ingest/parser.py` introduces a new failure mode (truncated CSV rows) not covered by `docs/failure-modes.md`. Add a row before merge.

**P2.weak-test** — `tests/test_login.py::test_lockout` mocks the lockout check itself, so the test would pass even with the bug above. Replace the mock with a real call to `is_locked()`.

**P3.docstring-drift** — `src/auth/login.py:10` docstring says "returns the user object" but the function returns a session token.
```

The pre-commit review-artifact validator looks for clause citations of the form `P[123]\.[a-z-]+` and rejects review files that contain none. It additionally requires that every cited clause is defined as a `**P[123].name**` bullet above — citing a well-formed but undefined clause (e.g., `P1.totally-made-up-clause`) is rejected as a shape-vs-membership Goodhart.

---

## Adversarial review technique

Review verdicts are only as strong as the probing that produced them. A review bead should not just read the diff and cite clauses — it should try to *falsify* the two registers. Every `bounded` row is a candidate for "the bound is on a proxy, not the actual property." For each row touching the modules under review, construct an input or sequence that triggers the documented failure mode but slips past the listed check, and document the attempt (and the result) in the review artifact.

**Common proxy-vs-property gaps to probe first:**
- A regex that checks the *shape* of a string — does the check also verify *membership* in a canonical set? (e.g., `P[123]\.[a-z-]+` matches any well-formed token, not only clauses defined in the rubric.)
- A literal-phrase `grep` (e.g., a check that only looks for the starter-rubric disclaimer sentence by exact substring) — does a trivial rewrite that keeps the Goodhart-able content but removes the phrase pass the check?
- A glob or literal match for one syntactic variant of a bug class (`|| true`) — is the check as broad as the failure-mode row claims (all of `|| true`, `|| :`, `|| 0`, `|| exit 0`)?
- A self-report signal (`<gate-result>`, `<confidence>`) — is there a matching observer that catches divergence, or only the self-report?

### Verified-failure-scenario beats "I read the code carefully"

Every P2 should be reproduced in a sandbox before being filed. A bead with a one-paragraph reproducer the next agent can re-run is strictly higher-quality than a bead with only a code citation. Recipe:

```bash
# Clone the repo into a scratch dir without beads/ state:
rsync -a --exclude='.beads/bd.sock' --exclude='.git' "$PROJECT_ROOT/" /tmp/sandbox/
cd /tmp/sandbox && git init -q && git add . && git commit -qm boot
./scripts/hooks/install.sh

# Mock `bd` so the in-progress-bead-dependent hooks fire:
printf '#!/bin/bash\necho "agent-template-fakeN IN_PROGRESS Title"\n' > /tmp/bin/bd
chmod +x /tmp/bin/bd; export PATH="/tmp/bin:$PATH"

# The `bd list --status=in_progress` regex in the hook matches IDs of shape
# [a-z_]*-[a-z0-9]*-[a-z0-9]* (three dash-separated segments) — the fake ID
# must match or the hook will silently no-op and produce a false-negative pass.
```

Stage the adversarial edit, attempt the commit (or whatever operation the mechanism protects), and record the exit code, the block message, and whether the attempt succeeded.

### Gotcha: pipe masks the exit code

`bash hook | tail -10; echo $?` prints `tail`'s exit code (always 0), not the hook's. The BLOCKED message in the output is the real signal — don't trust `$?` after a pipe. Use `bash hook 2>&1 || true; echo $?` or `${PIPESTATUS[0]}` to capture the hook's actual exit.

### Scope guardrail: tightenings become P2 follow-ups, not in-scope work

Adversarial probing almost always uncovers tightenings the bead's declared scope does not cover. Convention: findings inside scope get a verdict; tightenings outside scope become P2 follow-up beads filed inline in the review artifact so the knowledge does not evaporate when the compound bead deletes the artifact. Do not silently expand the review's scope to ship the tightening.
