# Decision register

Every place agent variance can enter this project must appear here, paired with the structural mechanism that bounds it. See `project-kickoff-prompt.md` §2 for the contract.

**Status values:** `bounded` | `ritual-bounded` | `agent-discretion` | `escalation-only`

| Decision point | Where it occurs | Bounding mechanism | Enforcement | Status |
|----------------|-----------------|--------------------|-------------|--------|
| Solution selection | impl bead execution | every acceptance criterion bound to a mechanical check | failure-mode register hook in scripts/hooks/install.sh | bounded |
| Acceptance interpretation | every "is it done" call | every PRD criterion expressible as test/type/proof | PRD review at Phase 1; re-validate on PRD edit | ritual-bounded |
| Review verdict | review beads | severity rubric in docs/skills/review-rubric.md; each finding cites a clause | review artifact validator hook; rubric-edit hook (pending) | ritual-bounded |
| Pattern extraction | compound beads | every promoted pattern carries a `model:` tag and a retire-on-upgrade rule | CLAUDE.md model-tag validator hook | bounded |
| Decomposition | Phase 2 | bead schema: scope, deps, criteria, size, register DoD | beads CLI + human dep-graph review at Phase 2 | ritual-bounded |
| Tool / search choice | execution | unconstrained — model picks | none (rationale: search strategy is exactly where we want model freedom) | agent-discretion |
| Model upgrade drift | model swap | every promoted pattern tagged with source model; retire unless re-validated | upgrade ritual: re-run both registers under the new model before resuming | ritual-bounded |
| Scope creep | every commit | `.current-bead-scope` declares allowed paths; infrastructure paths always allowed | scope enforcement hook in scripts/hooks/install.sh | bounded |
| Artifact format | review / research beads | review artifacts cite the rubric and contain a severity clause | review artifact validator hook | bounded |
| Sampling variance | every model invocation | `--print` mode, single-shot, fresh context per bead | scripts/ralph/ralph.sh invocation; one-bead-per-iteration | bounded |
| Confidence | exit signal | `<confidence>` tag with HIGH/MEDIUM/LOW | scripts/ralph/ralph.sh parse_confidence + auto-land routing | bounded |
| Verification truth | every "done" claim | one command from CLAUDE.md, not agent judgment | `<gate-result>` tag presence enforced by scripts/ralph/ralph.sh; pre-push re-run hook (pending) | ritual-bounded |
| Architectural choice | new subsystem design | escalate to human; agent does not decide alone | `<promise>BLOCKED</promise>` with reason | escalation-only |

## Pending promotions

Two rows are marked `ritual-bounded` pending audit beads that will promote them to `bounded`:

- **Verification truth** → `bounded` when `agent-template-4mw` lands the pre-push hook that re-runs the gate command and compares the real exit code against the self-reported `<gate-result>` tag.
- **Review verdict** → `bounded` when `agent-template-kjy` lands the pre-commit hook that rejects the unedited `docs/skills/review-rubric.md` starter.
