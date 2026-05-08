# Review: agent-template-tw4

## Scope

Reviewed the bootstrap-to-business hardening added in:

- `agent-template-6m4` (`auto-land: high` shipped default)
- `agent-template-4al` (missing local scanners fail closed after bootstrap)
- `agent-template-p8e` (explicit bootstrap-to-business transition wording)

Focus: whether a downstream project can still drift into Phase 3 with a permissive posture or retain bootstrap-only scanner behavior without the current checks noticing.

## Findings

### P2.weak-test — The bootstrap-to-business transition is still enforced only as template wording, not as a project-state artifact

`docs/failure-modes.md:41`, `docs/decision-register.md:19`, `tests/hooks/ralph.bats:501-509`, `README.md:26`, `README.md:91-93`, `project-kickoff-prompt.md:143`, `project-kickoff-prompt.md:154-157`

The current “coverage” for the bootstrap-to-business handoff is a pair of grep-based wording tests: one sentence in `README.md` and one sentence in `project-kickoff-prompt.md`. Those tests prove the template tells the user to make the switch explicit, but they do not prove that a bootstrapped project actually recorded the switch, actually confirmed `auto-land: high`, or actually confirmed scanners were installed before Phase 3 started. A downstream project can therefore enter Phase 3 with no durable switch artifact and the cited checks still pass.

This fits `P2.weak-test`: the test exists, but it constrains the prose, not the property the register row claims to cover.

### P2.weak-test — The scanner-exemption boundary is not pinned for the `bd`-absent branch that defines “bootstrap”

`scripts/hooks/parsers.sh:32-37`, `scripts/hooks/install.sh:86-105`, `docs/decision-register.md:18`, `tests/hooks/generated_hooks_e2e.bats:190-210`

`bd_bead_in_progress()` explicitly treats “`bd` is not installed” as success with an empty in-progress-bead result. `bootstrap_scanner_override_active()` then allows the bootstrap scanner override whenever `IN_PROGRESS_BEAD` is empty. The current tests only cover the happy “no bead” path and the mocked “bead in progress” path; they do not pin the branch where `bd` is absent and the hook silently decides that the repo is effectively still in bootstrap mode.

That leaves the business-mode boundary underconstrained against environment drift. Either “missing `bd` means bootstrap” is an intentional contract that should be documented and tested, or business mode should fail closed when `bd` is unavailable. Right now the branch exists, but the intended posture is not mechanically pinned.

This also fits `P2.weak-test`: the current tests do not constrain one of the exact branches that determines whether bootstrap-only scanner behavior remains available.

## Adversarial Register Falsification

### Failure-mode rows

- `docs/failure-modes.md:40` — Attempted to falsify the shipped `auto-land: high` posture. Result: no finding. `tests/hooks/ralph.bats` does mechanically pin the template repo’s own `CLAUDE.md` policy and surrounding wording.
- `docs/failure-modes.md:41` — Attempted to falsify the bootstrap-to-business handoff by asking whether the cited checks prove a downstream project actually performed the switch. Result: finding above. The cited checks only prove the template contains the instruction.

### Decision-register rows

- `docs/decision-register.md:18` — Attempted to falsify the “bootstrap scanner exemption” bound by tracing the actual branch conditions in `bd_bead_in_progress()` and `bootstrap_scanner_override_active()`, then comparing them with the existing tests. Result: finding above. The branch that defines “bootstrap because `bd` is absent” is not pinned.
- `docs/decision-register.md:19` — Attempted to falsify the “bootstrap-to-business transition” bound by looking for a durable switch artifact or a check that reads one before Phase 3. Result: finding above. The current bound is still ritual-only and the cited mechanical checks only verify wording.
- `docs/decision-register.md:23` — Attempted to falsify the shipped starter `auto-land` default by checking whether docs and code could disagree. Result: no finding. The code/test/doc trio for the shipped template default is pinned adequately.

## Recommendation

File follow-up implementation beads for:

1. A machine-readable bootstrap-to-business switch artifact or checklist check that Phase 3 can verify.
2. An explicit decision on the `bd`-absent scanner-exemption branch, with tests that pin whichever posture is intended.
