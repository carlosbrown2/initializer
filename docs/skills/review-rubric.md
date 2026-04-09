# Review Severity Rubric

## When to load

Load this skill at the start of every **review** bead. Every finding in a review artifact (`docs/reviews/<bead-id>.md`) must cite a clause from this rubric. The pre-commit review-artifact validator rejects review files that don't reference this rubric.

This rubric exists to **bound the "review verdict" decision point** in `docs/decision-register.md`. Without it, severity classification is the model's intuition — and two runs of the same review can produce different P1 sets. With it, severity is anchored to a checked-in standard, and the review's variance is funneled into the rubric's clauses.

This file is a starter rubric. Projects should refine the clauses in Phase 1 to match their domain (security-critical projects may add new categories; data-science projects may emphasize statistical correctness, etc.). Whatever clauses you add, the contract is that **every finding in every review cites a specific clause by name**.

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

The pre-commit review-artifact validator looks for clause citations of the form `P[123]\.[a-z-]+` and rejects review files that contain none.
