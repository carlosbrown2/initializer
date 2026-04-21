# Failure-mode register

Every module, function, and data flow that can fail must appear here, paired with a mechanical check that catches the failure before merge. See `project-kickoff-prompt.md` §1 for the contract.

**Status values:** `covered` | `proven-impossible` | `out-of-scope`

**Categories:** `correctness` | `concurrency` | `atomicity` | `input` | `resource` | `temporal` | `version` | `dependency` | `operational` | `security`

| Module / function | Failure mode | Category | Check (file:test) | Status |
|-------------------|--------------|----------|-------------------|--------|

<!--
Rows are added as the template grows. Three failure modes for the template itself
are tracked as open audit beads in the beads database (see `bd list --labels initializer-audit`):

  - gate-bypass: agent emits <gate-result>PASS</gate-result> without running the gate  → agent-template-4mw
  - parser edge cases in scripts/hooks/install.sh go unchecked                          → agent-template-mhd
  - unedited review-rubric starter lets "Review verdict" claim bounded falsely         → agent-template-kjy

Each bead's DoD includes adding a row here once the check ships.
-->
