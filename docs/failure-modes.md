# Failure-mode register

Every module, function, and data flow that can fail must appear here, paired with a mechanical check that catches the failure before merge. See `project-kickoff-prompt.md` §1 for the contract.

**Status values:** `covered` | `proven-impossible` | `out-of-scope`

**Categories:** `correctness` | `concurrency` | `atomicity` | `input` | `resource` | `temporal` | `version` | `dependency` | `operational` | `security`

| Module / function | Failure mode | Category | Check (file:test) | Status |
|-------------------|--------------|----------|-------------------|--------|
| scripts/ralph/ralph.sh gate-result parsing | agent emits `<gate-result>PASS</gate-result>` without running the gate (Goodhart / gate-bypass) | correctness | scripts/hooks/install.sh pre-push hook re-runs the gate command from CLAUDE.md and blocks push on non-zero exit; divergence against scripts/ralph/ralph.sh-persisted .last-gate-result is reported in the block message | covered |

<!--
Rows are added as the template grows. Two audit beads remain open for the template itself
(see `bd list --labels initializer-audit`):

  - parser edge cases in scripts/hooks/install.sh go unchecked                          → agent-template-mhd
  - unedited review-rubric starter lets "Review verdict" claim bounded falsely         → agent-template-kjy

Each bead's DoD includes adding a row here once the check ships.
-->
