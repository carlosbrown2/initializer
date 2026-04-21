# Failure-mode register

Every module, function, and data flow that can fail must appear here, paired with a mechanical check that catches the failure before merge. See `project-kickoff-prompt.md` §1 for the contract.

**Status values:** `covered` | `proven-impossible` | `out-of-scope`

**Categories:** `correctness` | `concurrency` | `atomicity` | `input` | `resource` | `temporal` | `version` | `dependency` | `operational` | `security`

| Module / function | Failure mode | Category | Check (file:test) | Status |
|-------------------|--------------|----------|-------------------|--------|
| scripts/ralph/ralph.sh gate-result parsing | agent emits `<gate-result>PASS</gate-result>` without running the gate (Goodhart / gate-bypass) | correctness | scripts/hooks/install.sh pre-push hook re-runs the gate command from CLAUDE.md and blocks push on non-zero exit; divergence against scripts/ralph/ralph.sh-persisted .last-gate-result is reported in the block message | covered |
| scripts/hooks/parsers.sh register-integrity parsers | edge cases (escaped pipes, Unicode, trailing whitespace, 5-column rows, multi-line continuation rows) silently accept malformed rows or reject valid ones; drift between the inlined pre-commit awk and the callable parsers | correctness | tests/hooks/parsers.bats exercises every parser against known-good and known-bad fixtures plus smoke tests against the real registers; scripts/hooks/install.sh sources parsers.sh so there is only one implementation | covered |
| docs/skills/review-rubric.md (Phase 1 completion) | unedited starter rubric ships with the project, letting "Review verdict" be claimed `bounded` while severity classification is still anchored only to generic clauses (Goodhart) | correctness | scripts/hooks/install.sh rubric-edit guard rejects commits while the rubric still contains the "This file is a starter rubric" disclaimer once any bead is in_progress; Phase 1 bootstrap (no in-progress bead) is exempt | covered |
| CLAUDE.md verification gate command | gate is structurally a no-op — trailing `\|\| true` binds to the whole `&&` chain so any in-chain failure (real syntax error, future check) silently exits 0; or a non-bash file (markdown) is added to a `bash -n` chain forcing a soft-fail escape. The pre-push hook re-runs whatever the gate is, so a no-op gate makes the hook a no-op too | correctness | tests/hooks/gate.bats asserts the extracted gate command has no `\|\| true` tail, contains no `.md` paths, passes against the current repo, and propagates non-zero exit when any in-chain clause is corrupted | covered |

<!-- Rows are added as the template grows. Each bead's DoD includes adding a row here once the check ships. -->
