# Project Kickoff Prompt

You are my engineering partner. Your job is to set up this project so that every change made by every future agent session is **provably correct, exhaustively constrained, and falsifiable by mechanical check**. The contracts below define *what* must be true at every checkpoint. *How* you satisfy them is your call — choose the strongest available technique, invent better ones when you can, and never substitute a procedure for a proof.

There are no required steps in this document. There are required outcomes. A phase is "done" when its outcome contract holds and I have approved it. Ask for what you need.

---

## The two registers

These are the mechanical backbone of the project. They are the only places where exhaustiveness is enforced — everything else flows from them.

### 1. `docs/failure-modes.md` — the failure-mode register

A live table. Every module, every function, every data flow that can fail must appear here, paired with a mechanical check that catches the failure before merge.

```
| Module / function   | Failure mode               | Category     | Check (file:test)                          | Status  |
|---------------------|----------------------------|--------------|--------------------------------------------|---------|
| ingest.parse_row    | malformed UTF-8            | input        | tests/test_ingest.py::test_invalid_utf8    | covered |
| ingest.parse_row    | row larger than 1 MB       | resource     | tests/test_ingest.py::test_oversized_row   | covered |
| ingest.write_batch  | crash mid-write            | atomicity    | tests/integration/test_atomic_write.py     | covered |
| stats.p_value       | numerical underflow        | correctness  | tests/test_stats.py::test_pvalue_bounds    | covered |
| stats.p_value       | non-monotone in sample size| correctness  | Z3 proof in proofs/pvalue_monotone.py      | covered |
```

**Categories** (use the strongest one that fits): `correctness`, `concurrency`, `atomicity`, `input`, `resource`, `temporal`, `version`, `dependency`, `operational`, `security`.

**Status values** (only one is acceptable at merge time):
- `covered` — there is a mechanical check, and it runs in the verification gate.
- `proven-impossible` — there is a written argument (1–3 sentences, in the row's notes) explaining why this failure mode cannot occur given the system's structure. "It won't happen in practice" is not acceptable; "the type system prevents this because…" is.
- `out-of-scope` — only valid for failure modes the PRD explicitly excludes. The PRD section must be cited inline.

**No row may be left blank, vague, or in `tested-manually` status.** If you cannot find a mechanical check for a row, you must either invent one, prove the failure mode impossible, or escalate.

**The exhaustiveness contract**: before any new module is merged, you must write a *negative-space proof* in the register — a line that says "the failure modes for this module are exactly the rows above, and here is why no other class of failure exists." If you cannot make that argument, the module is not ready to merge.

A pre-commit hook (see *Structural enforcement* below) parses this file and rejects commits where:
- any row has Status not in `{covered, proven-impossible, out-of-scope}`
- any row references a check file that does not exist

### 2. `docs/decision-register.md` — the decision register

A live table. Every place **agent variance** can enter the project — every decision the model makes that isn't fully determined by a checked-in artifact — must appear here, paired with the structural mechanism that bounds it.

This is the register that addresses the LLM-nondeterminism problem head-on. Sampling, batching, and model drift make it impossible for two runs of the same project to produce byte-identical code. The contract is **not** "the agent always makes the same choice." The contract is: **every choice the agent makes either lands inside a falsifiable channel or is rejected by a hook/gate/test.** The agent's freedom is funneled through narrow, mechanically-checkable channels. Outside the channels, the structure rejects the output regardless of which sample produced it.

Each row must be a single line — multi-line visual continuations are not parseable by the integrity hook. If a cell needs more text, just let the line wrap in your editor.

```
| Decision point            | Where it occurs           | Bounding mechanism                                                                | Enforcement                                                                       | Status           |
|---------------------------|---------------------------|-----------------------------------------------------------------------------------|-----------------------------------------------------------------------------------|------------------|
| Solution selection        | impl bead execution       | every acceptance criterion bound to a mechanical check                            | failure-mode register hook                                                        | bounded          |
| Acceptance interpretation | every "is it done" call   | every PRD criterion expressible as test/type/proof                                | PRD review at Phase 1; re-validate on PRD edit                                    | ritual-bounded   |
| Review verdict            | review beads              | severity rubric in docs/skills/review-rubric.md; each finding cites a clause      | review artifact validator hook                                                    | bounded          |
| Pattern extraction        | compound beads            | every promoted pattern carries a `model:` tag and a retire-on-upgrade rule        | CLAUDE.md model-tag validator hook                                                | bounded          |
| Decomposition             | Phase 2                   | bead schema: scope, deps, criteria, size, register DoD                            | beads CLI + human dep-graph review at Phase 2                                     | ritual-bounded   |
| Tool / search choice      | execution                 | unconstrained — model picks                                                       | none (rationale: search strategy is exactly where we want model freedom)          | agent-discretion |
| Model upgrade drift       | model swap                | every promoted pattern tagged with source model; retire unless re-validated       | upgrade ritual: re-run both registers under the new model before resuming         | ritual-bounded   |
| Scope creep               | every commit              | `.current-bead-scope` declares allowed paths; infrastructure paths always allowed | scope enforcement hook                                                            | bounded          |
| Artifact format           | review / research beads   | review artifacts cite the rubric and contain a severity clause                    | review artifact validator hook                                                    | bounded          |
| Sampling variance         | every model invocation    | `--print` mode, single-shot, fresh context per bead                               | ralph.sh invocation; one-bead-per-iteration                                       | bounded          |
| Confidence                | exit signal               | `<confidence>` tag with HIGH/MEDIUM/LOW                                           | ralph.sh parse_confidence + auto-land routing                                     | bounded          |
| Verification truth        | every "done" claim        | one command from `CLAUDE.md`, not agent judgment                                  | `<gate-result>` tag presence enforced by ralph.sh; tag truth is agent self-report | ritual-bounded   |
| Architectural choice      | new subsystem design      | escalate to human; agent does not decide alone                                    | `<promise>BLOCKED</promise>` with reason                                          | escalation-only  |
```

**Status values** (only these four are acceptable at merge time):
- `bounded` — there is a structural mechanism (hook, gate, test, schema) that mechanically constrains the agent's choice space. The mechanism is named in the row.
- `ritual-bounded` — the choice is bounded by a documented ritual or human step with a defined re-run cadence (e.g., "re-validate on PRD edit"). Weaker than `bounded`, but still a named, repeatable mechanism — not "we trust the model." The cadence must appear in the row's notes.
- `agent-discretion` — explicitly unconstrained because we want the model's freedom (e.g., tool selection, search strategy). Must be a deliberate choice with a one-line rationale, not an oversight.
- `escalation-only` — the decision is too high-stakes to leave to the agent; the agent must surface it via `<promise>BLOCKED</promise>` and let a human decide.

Statuses `tested-manually`, `we-trust-the-model`, `TODO`, or empty are not acceptable. Be honest about `ritual-bounded` rows: claiming `bounded` for a ritual is exactly the failure mode the register exists to prevent.

**The exhaustiveness contract**: there must be no decision point in this project that lacks a row in the register. If during execution the agent finds itself making a call that isn't covered by an existing row, it must add a new row (with a constraint and an enforcement mechanism) before closing the bead. The register grows over the project's lifetime as new decision points emerge.

**Baseline rows** that every project must have, populated in Phase 1:
1. Solution selection
2. Acceptance interpretation
3. Sampling variance
4. Verification truth
5. Scope creep

A pre-commit hook (see *Structural enforcement*) parses this file and rejects commits where:
- the file does not exist (after Phase 1)
- any baseline row is missing
- any row is multi-line, or has fewer than five columns
- any row's last cell (the Status column) is not exactly one of `{bounded, ritual-bounded, agent-discretion, escalation-only}`
- any path-shaped token in a Bounding mechanism or Enforcement column points to a file that does not exist on disk

---

## Outcome contracts

A phase is done when its contract holds and I approve. Sequence the sub-work however you want.

### Phase 1 — Spec

Done when **all** of the following hold and I have approved each:

- `tasks/<project>.prd.md` exists. It contains user stories with acceptance criteria, the dependency DAG, technology choices with rationale, every config decision, and zero TBDs. Every acceptance criterion is expressible as a mechanical check.
- `docs/failure-modes.md` exists, populated with the failure modes enumerable from the PRD before any code exists.
- `docs/decision-register.md` exists, populated with the five baseline rows plus any project-specific decision points the PRD reveals. Single-line rows only.
- `docs/skills/review-rubric.md` has been refined for this project's domain — at least one project-specific clause has been added or one starter clause adapted, and the "starter rubric" disclaimer at the top has been replaced with a project-named header. The shipped starter alone does not satisfy this contract; an unedited starter means "Review verdict" cannot legitimately be `bounded` in the decision register.
- `CLAUDE.md` is filled in: architecture decisions, code standards, the **single verification-gate command** that runs every check from the failure-mode register, invariants, and the confidence-routing policy.
- `docs/user-guide.md` exists as a stub that will grow as features land.
- The structural enforcement hooks have been installed via `./scripts/hooks/install.sh` and demonstrably reject the things they're meant to reject. ("Demonstrably" means: I've watched at least one intentionally-bad commit be blocked, not that the script ran without error.)
- No open assumptions remain about requirements, edge cases, target users, or risk tolerance. The codebase, the relevant external docs, and known failure modes for the chosen tech stack have been investigated. Top approaches have been presented with tradeoffs and I have picked one.

If you want a menu of techniques to draw from when populating the failure-mode register, load `docs/skills/backpressure-catalog.md`. It is a reference, not a curriculum. Use what fits, ignore the rest, invent better when you can.

### Phase 2 — Beads

Done when **all** of the following hold and I have approved the bead graph:

- Every PRD acceptance criterion is covered by at least one bead.
- Every bead has a declared file scope (the scope enforcement hook is on by default).
- Every bead is small enough to finish in a single fresh agent context window.
- The dependency graph has no cycles. `bd ready --json` returns a sensible starting set.
- Every implementation bead has, as part of its definition-of-done, an update to the failure-mode register for the module it touches.
- Every implementation bead that introduces a new decision point (a new place agent variance can enter) has, as part of its DoD, an update to the decision register.
- Cross-cutting checks that span multiple stories (e.g., a single property-test file covering invariants from several modules) get their own bead with its own quartet.

Each story decomposes into the **quartet**: `impl → review → pare-down → compound`. The four passes are kept structural — at worst they are redundant, at best they catch what a single-pass review would miss. Chain each quartet with `bd dep add`.

- **Implementation** — Build the feature *and* its checks. The failure-mode register must be updated before this bead closes; the decision register must be updated if a new decision point was introduced. Declare the bead's in-scope files in `.current-bead-scope`; the scope enforcement hook rejects out-of-scope changes.
- **Review** — Adversarial pass over the implementation. Try to make the registers' claims false. Cite the severity rubric (`docs/skills/review-rubric.md`) for every finding. Write findings to `docs/reviews/<story-id>.md`. P1 findings are fixed inline; P2s become new beads; P3s land in `archive.txt`.
- **Pare-down** — Read the review artifact. Remove dead code, collapse redundant abstractions, cut line count without losing functionality. Append a `## Pare-down Notes` section to the review artifact.
- **Compound** — Read the full arc (review artifact + pare-down notes + git diff). Promote durable patterns into `CLAUDE.md` `## Discovered Patterns` (cross-cutting) or `docs/skills/<domain>.md` (domain-specific). Every promoted pattern must carry a `model:` tag identifying which model authored it; this enables retire-on-upgrade. Ask: "would the system catch this class of issue automatically next time?" If no, add a hook, test, contract, or register row. Delete the review artifact.

### Phase 3 — Implementation (Ralph loop)

Done when every bead is closed and **all** of the following hold for every commit:

- The verification gate is green.
- The failure-mode register has been updated for any module the bead touched, with at least one new row per new failure mode and a negative-space proof if a new module was added.
- The decision register has been updated if a new decision point emerged.
- The commit's diff is within the bead's declared scope (enforced by the scope hook).
- A confidence signal was emitted.

The Ralph loop's hard rule still holds: **one bead per fresh agent session, then stop**. This is itself a decision-register entry: it bounds "context drift" by structurally preventing it. Memory persists through git — the registers, `CLAUDE.md`, `docs/skills/`, `scripts/ralph/patterns.md` — not through conversation history. (`scripts/ralph/archive.txt` is a per-run log, not persisted memory: it is gitignored.)

Beyond that hard rule, the per-iteration prompt should describe outcomes, not steps. The agent decides how to orient, how to search, how to validate. It must produce: a closed bead, a green gate, updated registers, and a confidence signal.

**Confidence routing**: three tiers — `HIGH`, `MEDIUM`, `LOW`. `CLAUDE.md` declares the auto-land policy under `## Confidence Routing`: `auto-land: all` (auto-land any tier, default), `auto-land: high` (auto-land HIGH only), or `auto-land: none` (every bead requires human approval).

**Retry rule**: if the verification gate fails twice on the same bead with the same error class, the third attempt must use a fundamentally different strategy or escalate via `BLOCKED`. Encoded in `ralph.sh`, not in prose.

### Phase 4 — Holistic review

Done when an **adversarial cross-cutting review** has tried to find a counterexample to every claim in both registers, across the full codebase.

This phase is not a code-style review. It is a *prove-the-system-wrong* exercise:
- For each row in the **failure-mode register**, ask: *can I construct an input or sequence that triggers this failure and slips past the listed check?*
- For each row in the **decision register**, ask: *can I find an agent action that fell inside this decision point but bypassed the listed bounding mechanism?* (E.g., a commit that should have been scope-blocked but wasn't, a pattern promoted without a model tag, a "done" claim not backed by the gate.)

If yes to either, file a bead.

Findings get classified `P1` (fix before shipping), `P2` (file a bead), `P3` (note in `archive.txt`).

### Phase 5 — Final compound

Done when **all** of the following hold:

- Every rule that turned out to matter is enforced by a hook, a test, a type, or a gate. Anything still living only in prose has been either deleted (it didn't matter) or promoted to structure (it did).
- Every bug class encountered during the project has a regression test in `tests/regression/`, wired into CI/pre-push.
- Every decision point that emerged during the project has a row in the decision register with status `bounded` or a deliberate `agent-discretion` rationale.
- `docs/skills/` has been pruned of stale entries and consolidated where overlapping.
- `CLAUDE.md` has been pruned of any rule now enforced structurally — the constitution should shrink, not grow, as the system matures.
- This kickoff prompt has been updated with anything the next project would benefit from. If a new technique earned its place, add it to `docs/skills/backpressure-catalog.md`. If a new class of decision point emerged, add it to the baseline rows in this prompt.

---

## Structural enforcement

If a rule matters, it must be enforced mechanically. Prose is for context; gates are for safety. Install these in Phase 1 and never bypass them.

**Pre-commit hooks** (install via `./scripts/hooks/install.sh`):

1. **Bead type fail-closed gate** — when a bead is in progress (per `bd list --status=in_progress`), `.current-bead-type` must exist and hold one of `impl|review|pare|compound|research`. Closes the "forget to write the marker → no enforcement" bypass that would otherwise let scope enforcement and write protection silently no-op.
2. **Scope enforcement** — rejects commits that touch files outside `.current-bead-scope`. `impl`/`pare`/`compound` beads MUST have a scope file present. Always-allowed infrastructure paths (the registers, the archive, the patterns file, the bead-marker files; plus `CLAUDE.md`, `docs/skills/`, and `tests/regression/` for compound beads) are exempt.
3. **Failure-mode register integrity** — rejects commits where any row in `docs/failure-modes.md` has a last cell that isn't exactly `covered|proven-impossible|out-of-scope`, or where a referenced check file does not exist on disk.
4. **Decision register integrity** — rejects commits where `docs/decision-register.md` is missing baseline rows, contains a multi-line/malformed row, has a row whose last cell isn't an acceptable Status, or names a bounding-mechanism file that does not exist.
5. **Review/research bead write-protection** — when `.current-bead-type` is `review` or `research`, only files under `docs/reviews/` may change.
6. **Review artifact validator** — when `.current-bead-type=review`, files staged in `docs/reviews/` must cite `docs/skills/review-rubric.md` and contain at least one severity clause matching `P[123].<clause-name>`.
7. **CLAUDE.md model-tag validator** — every `### ` entry under `## Discovered Patterns` in `CLAUDE.md` must contain an anchored `model:` line so it can be retired or re-validated on model upgrade.
8. **CLAUDE.md size guard** — rejects commits that push `CLAUDE.md` past the line limit (default 200). Domain knowledge belongs in `docs/skills/`, not in the constitution.
9. **Commit-message format** — `feat|fix|refactor|review|compound|research|docs|chore|test: ...`.

A tenth hook, **dependency hallucination check** (`dep-hallucinator` or equivalent on every manifest change), ships commented out in `install.sh` — uncomment after installing the tool of your choice.

**The verification gate is not a pre-commit hook.** It is the single command declared in `CLAUDE.md`, e.g.:
```
mypy --strict src/ tests/ && pytest && hypothesis --profile=ci && python -m proofs && dep-hallucinator check && ruff check
```
The gate is enforced at **two points**: (1) the agent runs it during a bead and reports via `<gate-result>PASS|FAIL</gate-result>`, which `ralph.sh` parses and persists to `.last-gate-result`; (2) the pre-push hook installed by `scripts/hooks/install.sh` extracts the gate from `CLAUDE.md`, re-runs it on `git push`, and blocks the push if the real exit code diverges from the self-report. Do not bury slow checks in "I'll run them later."

---

## Standing rules

- **Never guess.** If you're unsure, ask me.
- **Never bypass a hook.** If a hook is wrong, fix the hook.
- **The verification gate is the merge contract.** A green gate is a merge license. A red gate is a stop signal. There is no third option.
- **Exhaustiveness is the agent's job.** Completeness of both registers is on you, not on me. Negative-space proofs are required for every new module; new decision points must be added to the decision register the moment they emerge.
- **Constrain, don't dictate.** Your job is to bound the agent's choice space, not to script its decisions. If you find yourself writing prose like "first do X, then do Y," look for a hook or schema that would make the prose unnecessary.
- **Methodology is yours to choose.** If you find a stronger technique than what's in `docs/skills/backpressure-catalog.md`, use it and update the catalog. Do not feel constrained by what previous projects used.
- **When a rule starts mattering, encode it.** If you find yourself reminding the agent of a rule in prose, that rule should become a hook, a test, a schema, or a type. Promote, don't repeat.
- **Confidence is reported, not negotiated.** Emit `<confidence level="HIGH|MEDIUM|LOW">reason</confidence>` after each bead. Routing happens in `ralph.sh`.
- **Tag patterns with the model that wrote them.** Every entry under `CLAUDE.md ## Discovered Patterns` carries a `model:` tag. On model upgrade, every tagged pattern is re-validated or retired. This bounds "model upgrade drift" in the decision register.
- **Structural over verbal at every layer.** This document is the smallest possible set of contracts. Anything you'd want to add to it should probably be a hook instead.