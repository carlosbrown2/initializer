# Project Kickoff Prompt

You are my engineering partner for this project. Follow this workflow to setup this project exactly, phase by phase. Do not skip ahead. Wait for my approval before moving to the next phase.

---

## Phase 1: Spec

### 1a. Discovery
Grill me with questions before writing anything. Cover:
- Requirements and constraints
- Target users and use cases
- Edge cases and failure modes
- Which backpressure techniques from the catalog in Phase 1e apply to this project
- Which domain-specific skills from `docs/skills/` (if any exist from prior projects) are relevant

Do not stop asking until you have no remaining ambiguity.

### 1b. Research
Before proposing an approach, research three things and present your findings:
1. **Codebase patterns** — What already exists? What conventions must we follow?
2. **External docs & best practices** — Framework docs, library APIs, known pitfalls
3. **Edge cases & failure modes** — What breaks under load, bad input, network failure, partial state?

If the domain warrants it, produce a standalone reference document in `docs/` (e.g., literature review, prior art survey). This persists across sessions and keeps domain knowledge out of conversation context.

**Codebase search strategy:** Use the right tool for the query type:
- **Exact matches** (function names, imports, error strings, config keys): `grep`, `ripgrep`, AST navigation
- **Semantic similarity** (find code that does something similar, find related patterns, "how do we handle X"): semantic code search via the project's vector index (see Phase 1f setup)
- When unsure, start with grep. Escalate to semantic search when grep returns too many irrelevant results or when the query is conceptual rather than lexical.

**Large codebases (100K+ lines):** Evaluate tools that reduce navigation overhead — grep and AST navigation don't scale well when naming is inconsistent or the query is conceptual. Options:
- **Semantic MCP tools** (e.g., [Context+](https://github.com/ForLoopCodes/contextplus)) — embedding-based code search, blast radius analysis, and spectral clustering. Good for "find similar" and conceptual queries.
- **Context compilation via RLM** (e.g., [rlm_repl](https://github.com/fullstackwebdev/rlm_repl)) — loads the full repo into a REPL workspace (not into tokens), then programmatically traverses, slices, and searches it to build a minimal context pack for the current task. Treats tokens as compute rather than storage — the model receives a pre-compiled summary instead of raw source trees. Useful when the repo is too large for even semantic search to keep context clean.

These add little value for small repos where grep suffices, but at scale they prevent context windows from filling with irrelevant code.

### 1c. Approach Selection
Present the top approaches with tradeoffs. I will pick one. Do not proceed until I confirm.

### 1d. Write the PRD
Formalize the approved approach into a PRD in `tasks/`. The PRD is the single source of truth for what we're building. It must include:
- User stories with acceptance criteria (checkboxes)
- A dependency DAG between user stories
- Technology choices with explicit rationale
- A config schema (if applicable)
- All open questions resolved — no TBDs survive this phase

Iterate on the PRD with me until all decisions are locked. Every downstream artifact (beads, code, tests) traces back to the PRD.

### 1e. Backpressure & Verification Design
Write a standalone backpressure document (`docs/backpressure.md`) that describes how the system prevents bad data or state from propagating. This is not a section in the PRD — it's a first-class design artifact.

Start from the **backpressure catalog** below. For each category, determine which techniques apply to this project based on the codebase, domain, and risk profile. Not every project needs every technique — select the ones that catch real failure modes for this specific system. Document your selections and rationale.

#### Backpressure Catalog

**Verification & correctness** — catches bugs before they reach production:

| Technique | What it catches | When to consider |
|-----------|----------------|-----------------|
| **Static typing** (e.g., mypy --strict, tsc --strict) | Type mismatches, missing annotations, wrong signatures | Always — baseline for any typed language |
| **Unit tests** | Logic errors, regressions, data corruption | Always |
| **Property-based tests** (e.g., Hypothesis, fast-check) | Edge cases no one thought to write tests for; mathematical invariant violations | When code has mathematical invariants, parsers, serialization round-trips, or complex input spaces |
| **Formal verification / SMT** (e.g., Z3, Dafny) | Proves properties hold for ALL inputs, not just sampled ones | When correctness is non-negotiable for specific formulas or mappings (e.g., bounds proofs, injectivity) |
| **Fuzz testing** (e.g., AFL, cargo-fuzz) | Crashes, hangs, and undefined behavior on malformed input | When code processes untrusted or complex input formats |
| **Integration tests** | Failures at component boundaries, API contract violations | When multiple services or modules interact |
| **Schema validation** (e.g., pydantic, JSON Schema, protobuf) | Malformed data crossing boundaries, schema drift between stages | When data flows between stages, services, or systems |
| **Design by contract** (e.g., deal, icontract, dpcontracts) | Pre/postcondition violations, invariant breakage on every call | When functions have non-obvious requirements or guarantees that types alone can't express |
| **Snapshot / golden tests** | Silent regressions in output format, numerical drift | When outputs must be deterministic and stable across changes |
| **Distributional / statistical checks** | Subtle corruption that produces plausible but meaningless statistical results | When code produces probabilistic outputs, p-values, or statistical claims |
| **Static analysis beyond types** (e.g., Bandit, Semgrep, CodeQL, pylint, SonarQube) | Security anti-patterns (hardcoded secrets, injection vectors, unsafe deserialization), excessive complexity, dead code, supply chain vulnerabilities | Always — types catch structural issues; static analysis catches semantic anti-patterns types can't express |
| **Dependency vulnerability scanning** (e.g., pip-audit, npm audit, Dependabot, Snyk) | Known CVEs in transitive dependencies, outdated packages with security patches | Always — your code may be correct but your dependencies aren't |
| **Dependency hallucination detection** (e.g., dep-hallucinator, manual registry checks) | Packages recommended by AI that don't exist or are typosquat/slopsquat targets | Always — runs in every verification gate pass. See Standing Rules for details |
| **Mutation testing** (e.g., mutmut, cosmic-ray for Python; Stryker for JS/TS) | Weak test suites that pass but don't actually catch bugs; tests that assert nothing meaningful | When you need confidence that your test suite is effective, not just green |
| **Browser/E2E automation** (e.g., Puppeteer MCP, Playwright, Cypress) | Visual regressions, broken user flows, client-server integration failures | When the project has a UI — agents can verify features the way a human would, catching issues unit tests miss |

**Concurrency & data race prevention** — catches bugs from parallelism and shared state. These are among the hardest bugs to reproduce and easiest to miss:

| Technique | What it catches | When to consider |
|-----------|----------------|-----------------|
| **Race detection** (e.g., Go race detector, ThreadSanitizer, `PYTHONHASHSEED` randomization) | Data races, non-deterministic behavior from unsynchronized shared state | When code uses threads, async, multiprocessing, or shared mutable state |
| **Deadlock detection** (e.g., lock-order analysis, timeout-based acquisition) | Circular lock dependencies, indefinite hangs under contention | When code acquires multiple locks or coordinates between threads |
| **Atomicity guarantees** (e.g., database transactions, file locking, compare-and-swap) | Partial updates visible to concurrent readers, torn writes, lost updates | When multiple writers can modify the same resource, or readers must see consistent state |
| **Deterministic concurrency testing** (e.g., Loom for Rust, systematic schedule exploration) | Bugs that appear only under specific thread interleavings | When correctness depends on ordering of concurrent operations |

**Runtime & operational** — catches failures in running systems. These apply primarily to service-oriented architectures; most batch/pipeline projects need only timeouts and idempotency.

| Technique | What it catches | When to consider |
|-----------|----------------|-----------------|
| **Rate limiting** | Resource exhaustion from excessive requests | When exposing APIs or processing external input |
| **Circuit breakers** | Cascading failures from downstream dependency outages | When calling external services that can fail |
| **Retries with backoff** | Transient failures (network blips, temporary unavailability) | When operations can fail transiently and are idempotent |
| **Timeouts** | Hung connections, slow dependencies blocking progress | When calling any external service or running unbounded operations |
| **Queue depth limits** | Memory exhaustion from unbounded queues, producer-consumer imbalance | When using async queues or message brokers |
| **Backoff strategies** | Thundering herd after recovery, retry storms | When many clients retry simultaneously |
| **Idempotency** | Duplicate processing from retries, at-least-once delivery | When operations have side effects and may be retried |
| **Health checks / liveness probes** | Silent process death, zombie services | When running long-lived services |
| **Graceful degradation** | Total outage when a non-critical subsystem fails | When some features are optional and the system should partially function without them |

#### Pattern sketches for less common techniques

Most agents know how to write unit tests. These sketches show the *shape* of less familiar techniques so you can recognize where they fit and write a project-specific version in `docs/backpressure.md`.

**Property-based test (Hypothesis)** — proves invariants hold across thousands of random inputs:
```python
from hypothesis import given, strategies as st

@given(st.binary(min_size=1), st.binary(min_size=1))
def test_ncd_symmetric(a: bytes, b: bytes) -> None:
    """NCD(a,b) == NCD(b,a) for all inputs."""
    assert ncd(a, b) == pytest.approx(ncd(b, a))

@given(st.lists(st.floats(min_value=0, max_value=1), min_size=2).filter(lambda x: sum(x) > 0))
def test_normalize_sums_to_one(weights: list[float]) -> None:
    """Normalization always produces a valid distribution."""
    dist = normalize(weights)
    assert all(p >= 0 for p in dist)
    assert sum(dist) == pytest.approx(1.0)
```
Use when: code has mathematical invariants (symmetry, bounds, idempotency), serialization round-trips, or parsers. Hypothesis finds the edge cases you wouldn't write by hand.

**SMT proof — negation pattern (Z3)** — proves a property holds for ALL inputs by showing no counterexample exists:
```python
from z3 import Reals, Solver, And, Not, unsat

def test_formula_bounded() -> None:
    """Prove output is in [0, 1] for all valid inputs."""
    x, y, z = Reals("x y z")
    precondition = And(x > 0, y > 0, z > 0, z <= x + y)
    result = (z - min(x, y)) / max(x, y)
    s = Solver()
    s.add(And(precondition, Not(And(result >= 0, result <= 1))))
    assert s.check() == unsat  # no inputs violate the bound
```
Use when: you need exhaustive proof for a specific formula or mapping (bounds, injectivity, ordering preservation). Scale with bounds on input sizes to keep solving tractable.

**SMT — covering array generation (Z3)** — generates minimal test suites covering all pairwise (or t-wise) parameter interactions:
```python
from z3 import Int, Solver, Or, sat
from itertools import combinations

def generate_pairwise_tests(params: dict[str, list[int]]) -> list[dict[str, int]]:
    """Find minimal test cases covering all 2-way parameter combos."""
    names = list(params.keys())
    uncovered = {(a, va, b, vb) for a, b in combinations(names, 2)
                 for va in params[a] for vb in params[b]}
    tests = []
    while uncovered:
        s = Solver()
        zvars = {n: Int(n) for n in names}
        for n, vals in params.items():
            s.add(Or(*(zvars[n] == v for v in vals)))
        assert s.check() == sat
        row = {n: s.model()[zvars[n]].as_long() for n in names}
        tests.append(row)
        uncovered -= {(a, row[a], b, row[b]) for a, b in combinations(names, 2)}
    return tests
```
Use when: testing configurable systems with many parameters where bugs stem from value combinations. Produces far fewer tests than exhaustive enumeration while guaranteeing interaction coverage.

**SMT — model-based test data (Z3)** — generates concrete inputs satisfying complex constraints from a spec:
```python
from z3 import Int, Solver, And, sat, Optimize

def generate_test_inputs_for_path(guards: list) -> dict | None:
    """Solve path constraints to produce feasible test data."""
    s = Optimize()
    x, y = Int("x"), Int("y")
    for guard in guards:  # e.g., [x > 0, y == x + 1, y < 100]
        s.add(guard)
    if s.check() == sat:
        m = s.model()
        return {"x": m[x].as_long(), "y": m[y].as_long()}
    return None  # path infeasible — discard
```
Use when: deriving diverse test inputs from a state machine, protocol spec, or complex preconditions. Use `Optimize` with `minimize`/`maximize` to get boundary values automatically.

**Mutation testing** — tests that test your tests:
```python
# Run: mutmut run --paths-to-mutate=src/mymodule.py --tests-dir=tests/
#
# mutmut introduces mutations like:
#   - `x > 0`  →  `x >= 0`     (boundary)
#   - `x + y`  →  `x - y`      (operator)
#   - `return result` → `return None`  (return value)
#   - `if cond:` → `if not cond:`      (negate)
#
# Each surviving mutant = a bug your tests wouldn't catch.
# Target: < 10% surviving mutants for critical modules.
#
# Example CI gate:
#   mutmut run --paths-to-mutate=src/critical.py
#   mutmut results
#   # Fail if survival rate > threshold
```
Use when: you need confidence that your test suite is effective. Green tests mean nothing if they don't fail on bugs. Especially valuable after writing tests for mathematical or financial code where off-by-one or wrong-operator bugs have real consequences.

**Concurrency safety check** — catches races and non-determinism from parallelism:
```python
import subprocess
import os

def test_deterministic_under_hash_randomization() -> None:
    """Run the same computation with different PYTHONHASHSEED values.
    Non-deterministic dict/set iteration will produce different results."""
    results = []
    for seed in ["0", "42", "12345"]:
        env = {**os.environ, "PYTHONHASHSEED": seed}
        out = subprocess.check_output(
            ["python", "-c", "from mymodule import compute; print(compute())"],
            env=env,
        )
        results.append(out)
    assert len(set(results)) == 1, f"Hash randomization caused different outputs: {results}"

# For threaded code, use concurrent stress tests:
from concurrent.futures import ThreadPoolExecutor

def test_concurrent_writes_atomic() -> None:
    """Verify shared state isn't corrupted under concurrent access."""
    counter = SharedCounter()  # your class under test
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(counter.increment) for _ in range(10_000)]
        for f in futures:
            f.result()
    assert counter.value == 10_000, f"Lost updates: got {counter.value}"
```
Use when: code uses threads, multiprocessing, async, or iterates over dicts/sets where ordering matters. `PYTHONHASHSEED` randomization is the cheapest concurrency check — catches hidden ordering dependencies with zero code changes.

**Distributional check** — catches statistical bugs that produce plausible but wrong results:
```python
def test_null_distribution_not_degenerate(null_values: list[float]) -> None:
    """Null distribution must have variance — otherwise the metric ignores permutation."""
    assert np.std(null_values) > 1e-8, "Null has zero variance; metric is insensitive"
    first_half = np.mean(null_values[: len(null_values) // 2])
    second_half = np.mean(null_values[len(null_values) // 2 :])
    assert abs(first_half - second_half) < 3 * np.std(null_values) / np.sqrt(len(null_values))
```
Use when: code produces p-values, confidence intervals, or any statistical claim. These checks catch silent corruption that passes all other tests.

The backpressure document must cover:
- Which techniques from the catalog were selected and why
- What class of bug each catches in this specific system
- How validation flows through the system (which checks run where, what halts on failure)
- How an autonomous agent self-corrects when a check fails
- **Which techniques produce cross-cutting test artifacts** (test files that span multiple user stories and don't belong to any single story) — these must be called out explicitly so they get their own beads in Phase 2

After completing the backpressure document, update the PRD to reference it. Both must agree.

### 1f. Documentation & Tooling Setup
Create these files at the project root if they don't exist:
- `CLAUDE.md` — Single authoritative project rules file (auto-loaded by Claude Code). Contains core architecture decisions, code standards, verification layers, invariants, do-not rules, and a `## Discovered Patterns` section. Keep ≤ 1000 lines. **Domain-specific knowledge belongs in `docs/skills/`, not here** — see skills structure below. Include a `## Confidence Routing` section with the auto-land policy for this project (default: `auto-land: all`).
- `progress.txt` — Running log of decisions and iteration history. Include a `## Codebase Patterns` section at the top for cross-session knowledge transfer. Session-specific context goes here; durable patterns belong in `CLAUDE.md`. Subject to **reversible compaction** — see compaction rules below.
- A human-readable `docs/user-guide.md` for end users (update as features land)

#### Skills directory (`docs/skills/`)

Domain-specific knowledge lives in `docs/skills/` as standalone markdown files, loaded by the agent **only when a bead touches that domain**. This keeps `CLAUDE.md` lean and context windows clean.

Each skill file covers one domain (e.g., `docs/skills/database-migrations.md`, `docs/skills/frontend-components.md`, `docs/skills/api-auth.md`). Structure:
- **When to load**: A one-line description of which beads/files trigger loading this skill
- **Conventions**: Patterns, naming rules, file structure for this domain
- **Pitfalls**: Known failure modes specific to this domain
- **Examples**: Canonical code snippets the agent should follow

During Phase 2 (bead creation), tag each bead with relevant skill files. During Phase 3, the agent's "Read context" step loads the tagged skill files alongside `CLAUDE.md`.

Create skill files proactively during Phase 1 for any domain the PRD touches that has project-specific conventions. Additional skill files are created organically during compound beads when a pattern is too domain-specific for `CLAUDE.md` but too valuable to lose.

#### Reversible compaction for `progress.txt`

`progress.txt` grows monotonically during implementation. To prevent context rot:

**Threshold trigger:** When `progress.txt` exceeds 500 lines, compaction runs automatically at the start of the next ralph.sh iteration (before the agent picks up a bead).

**Scheduled trigger:** Every 10 ralph.sh iterations, compaction runs as periodic maintenance regardless of file size.

**Compaction procedure:**
1. **Extract durable learnings** — Any pattern or decision that generalizes goes to `CLAUDE.md` `## Discovered Patterns` or a skill file in `docs/skills/`. These survive compaction.
2. **Reversible compaction** — Replace detailed session logs with pointers: `[Iterations 1-15: see git log main~15..main~1 and bd history]`. The full history remains recoverable via git and beads, but doesn't consume context.
3. **Preserve recent context** — Keep the last 10 iterations' entries in full detail. Only compact entries older than that.
4. **Keep the `## Codebase Patterns` section intact** — This section is never compacted; it's updated in place.

The compaction itself is a maintenance step in `ralph.sh`, not a bead. It runs before the agent's Orient step.

#### Semantic code search setup

For projects where semantic search adds value (agent's judgment, but especially for codebases 50K+ lines or with inconsistent naming):

1. Set up a local vector index using Chroma (Python projects) or pgvector (if PostgreSQL is already in the stack). Index the codebase at the function/class level using AST-aware chunking (Tree-sitter).
2. Document the search interface in `CLAUDE.md` so agents know how to query it.
3. Re-index after each implementation bead lands (add to `ralph.sh` post-commit step).

This is optional infrastructure — the agent evaluates whether it's warranted during Phase 1b and proposes setup if so. Small repos where grep suffices should skip this.

### 1g. Logging Design
Before implementation, propose a logging strategy sufficient to diagnose issues in production. I must approve it before we build.

### 1h. Structural Constraint Setup

Set up pre-commit hooks that enforce hard constraints the verification gate alone cannot catch:

1. **Scope enforcement** — Each bead description declares its in-scope files/directories (see Phase 2b). The pre-commit hook rejects commits that modify files outside the declared scope. This prevents agents from making "drive-by" changes to unrelated code.
2. **Dependency hallucination check** — Run `dep-hallucinator` (or equivalent registry validation) against any changes to dependency manifests (requirements.txt, package.json, pyproject.toml, Cargo.toml, etc.). Reject commits that introduce packages not found in their respective registries or that match known typosquat patterns.
3. **CLAUDE.md size guard** — Reject commits that push `CLAUDE.md` beyond the line limit (default: 200 lines). Forces the agent to offload domain knowledge to `docs/skills/` instead.
4. **Commit message format validation** — A commit-msg hook enforces that all commit messages start with a valid type prefix (`feat`, `review`, `refactor`, `docs`, `fix`, `chore`, `test`). This structurally enforces the naming convention from `prompt.md`.
5. **Review bead write protection** — When `.current-bead-type` contains `review`, the pre-commit hook rejects changes to any file outside `docs/reviews/`. The agent writes this marker when claiming a bead and removes it on close.

These hooks are **hard enforcement** — they block the commit regardless of what the prompt says. The prompt also instructs agents to respect scope and validate dependencies (soft guidance), but the hooks are the backstop.

Install hooks via a setup script created during this phase. Document them in `CLAUDE.md` so agents understand the constraints.

---

## Phase 2: Implementation Plan (Beads)

Install [Beads](https://github.com/steveyegge/beads) (`brew install beads` or `npm install -g @beads/bd`) and initialize it in the project with `bd init` if not already done.

Break the approved PRD into **beads** — structured, dependency-aware issues tracked via the `bd` CLI. Do not use markdown plans or flat TODO lists. Beads is the single source of truth for all work.

### 2a. File Epics
Create top-level epics for each major area of the PRD (typically one per user story):
```
bd create "Epic title" --type epic -p <priority>
```

### 2b. File Quartets Under Epics
For each implementation issue, create a **quartet** — an implementation bead followed by a **triad** of three QA beads:

1. **Implementation** — Build the feature AND its backpressure tests. Backpressure is built during implementation, not bolted on during review. Before writing any new function, search the codebase for existing ones that do the same thing (use semantic search for "find similar" queries, grep for exact matches). Do not add defensive code for conditions the system's design makes structurally impossible. Prefer idiomatic language patterns over verbose equivalents. Priority matches the epic. **Declare in-scope files/directories** in the bead description — the pre-commit hook enforces this boundary. **Tag relevant skill files** from `docs/skills/` that the agent should load.
2. **Review** — Multi-pass code review. Verify all applicable backpressure techniques from `docs/backpressure.md` have tests. A missing backpressure test is a **P1** — fix inline. File P2s as new beads, log P3s to `progress.txt`. **Write a structured review artifact** to `docs/reviews/<story>-review.md` with: findings by severity, patterns observed, verbose/dead code flagged for pare-down, and learnings for compound. This artifact is the primary information bridge to pare-down and compound.
3. **Pare-down** — Simplify without removing functionality. **Read `docs/reviews/<story>-review.md`** to see what the review flagged as verbose or redundant. Remove dead code, collapse unnecessary abstractions, reduce line count. Append a `## Pare-down Notes` section to the review artifact with what was simplified and why.
4. **Compound** — Learning feedback loop. **Read `docs/reviews/<story>-review.md`** (including pare-down notes) and the git diffs from the quartet's commits to see the full arc. Append patterns to `CLAUDE.md` `## Discovered Patterns` (if they generalize) or create/update a skill file in `docs/skills/` (if they're domain-specific). Ask: "Would the system catch this class of issue automatically next time?" If no, add a test, lint rule, or contract. If a new bug class is identified, add a test to `tests/regression/` to prevent recurrence. Delete the review artifact after extracting learnings — it has served its purpose.

Chain each quartet with dependencies: `bd dep add <review> <impl>`, `bd dep add <pare-down> <review>`, `bd dep add <compound> <pare-down>`.

#### Quartet serialization

Ask the user which execution model they prefer:

- **Strict** — Chain the next story's implementation to the previous story's compound. Maximizes learning transfer; choose when correctness matters more than speed.
- **Parallel where independent** — Only chain quartets with a data or code dependency. Choose when delivery speed matters more.

#### Cross-cutting test beads

Some backpressure techniques produce test files spanning multiple user stories (e.g., a single SMT proof file, or a distributional checks file across stages). The backpressure document flags these in Phase 1e. Create a **dedicated bead** for each, depending on the implementations they test, with its own review triad.

Each bead must be:
- **Small enough** to complete in one agent context window
- **Independently validatable** — a test passes, a type checks, a command returns expected output

### 2c. Review the Bead Graph
Run `bd ready --json` to verify the dependency graph makes sense. Present the full bead graph to me. I will approve before implementation begins.

### 2d. Refine
Iterate on the beads up to 5 times — proofread, refine descriptions, tighten dependencies, ensure workers will have a smooth time implementing each issue. Stop when you can't meaningfully improve them further.

---

## Phase 3: Implementation (Ralph Loop)

Execute beads using the Ralph pattern: **each iteration is a fresh agent instance with clean context that completes exactly ONE bead and then stops.** An agent must never work on a second bead in the same session. Memory persists via git history, `CLAUDE.md`, `docs/skills/`, `progress.txt`, and the beads database.

### Setup

**Branching strategy:** All work commits to `main`. Each bead is a single atomic commit. If a bead produces a bad commit, `git revert` the commit and re-open the bead.

Create two artifacts before starting the loop:

**`scripts/ralph/prompt.md`** — Per-iteration instructions piped to each Claude Code instance. Branches on bead type (implementation, review, pare-down, compound). Must enforce the **one bead per iteration** rule: the agent completes one bead, emits a done signal (e.g., `<promise>BEAD_DONE</promise>`), and stops. A separate completion signal (e.g., `<promise>COMPLETE</promise>`) is emitted when `bd ready` returns no work.

The prompt must also instruct the agent to emit a **confidence signal** after completing the bead:
```
<confidence level="HIGH|MEDIUM|LOW">One-line rationale for the confidence level</confidence>
```

**`scripts/ralph/ralph.sh`** — Shell script that loops: run `claude --dangerously-skip-permissions --print < prompt.md`, check for the completion signal, sleep briefly, repeat. Accept an optional max-iteration count to prevent runaway loops. Log iteration count and bead status on each pass.

`ralph.sh` additional responsibilities:
- **Compaction check:** Before each iteration, check if `progress.txt` exceeds 500 lines or if 10 iterations have passed since last compaction. If either, run the compaction procedure (see Phase 1f) before spawning the agent.
- **Confidence routing:** After a bead completes, check the confidence level. If confidence is **HIGH** AND the verification gate passed: auto-land the commit without waiting for human approval, regardless of bead type. **MEDIUM** confidence pauses for human review. **LOW** always pauses. The review triad exists to catch implementation mistakes — requiring human approval before the triad can run defeats the purpose of the Ralph loop. Log all auto-land decisions for auditability.
- **Exit signal routing:** Handle structured exit states beyond BEAD_DONE/COMPLETE. `BLOCKED` auto-files a blocker bead, unclaims the current bead, and proceeds. `REWORK_REQUIRED` re-opens the prerequisite bead and unclaims the current bead. Both reset retry tracking and log to the confidence log.
- **Semantic index refresh:** After each implementation bead lands (if semantic search is set up), re-index the codebase.

**Confidence routing override:** The default auto-land policy can be overridden per-project in `CLAUDE.md` under a `## Confidence Routing` section. Options:
- `auto-land: all` (default — all bead types auto-land at HIGH confidence + green gate)
- `auto-land: review, pare-down, compound` (more conservative — implementation beads always require human approval)
- `auto-land: compound` (most conservative — only auto-land the lowest-risk bead type)
- `auto-land: none` (fully manual — every bead requires human approval)

### The Loop

For each iteration, `prompt.md` instructs the agent to:

1. **Orient** — Run `bd ready` to get the highest-priority unblocked bead. Claim it. If nothing ready, emit the completion signal and stop.
2. **Read context** — Check `CLAUDE.md` `## Discovered Patterns`, `progress.txt` `## Codebase Patterns`, the bead description, referenced files, and **any skill files tagged on the bead** from `docs/skills/`. Do not load skill files that aren't tagged — keep context clean.
3. **Execute** — Complete the bead according to its type. Use semantic search for "find similar" queries, grep for exact matches. Respect the declared file scope — the pre-commit hook will reject out-of-scope changes.
4. **Validate** — Run the project's verification gate (defined as a single command in `CLAUDE.md`, e.g., `mypy --strict src/ scripts/ tests/ && pytest && dep-hallucinator check`). The gate always includes dep-hallucinator. Do NOT proceed on a red gate.
5. **Land** — Commit (`feat: [bead-id] - [title]`), close the bead (`bd close <id>`), file any discovered bugs/debt as new beads. Emit the confidence signal.
6. **Update shared knowledge** — Append patterns to `CLAUDE.md` (if they generalize) or the appropriate skill file in `docs/skills/` (if domain-specific). Log session context to `progress.txt` (date, bead-id, files changed, learnings). Run `bd sync --flush-only`.

### Dynamic Re-decomposition

If during execution an agent discovers a bead is significantly more complex than its description suggests, it may **dynamically split the bead** under these rules:

- **≤ 3 sub-beads:** Auto-split. Create the sub-beads with proper dependencies, close the original bead as "decomposed," and pick up the first sub-bead in the same iteration. Each sub-bead gets its own quartet (implementation + review/pare-down/compound). Log the decomposition in `progress.txt`.
- **> 3 sub-beads:** Escalate. Unclaim the bead, file a blocker bead describing the unexpected complexity, and emit `BEAD_DONE` to stop the iteration. The human reviews and approves the re-decomposition before work continues.

The threshold of 3 can be overridden in `CLAUDE.md`.

### Retry and escalation

If the verification gate fails 3 times on the same bead, the agent must unclaim it and file a blocker bead describing the failure. This prevents an agent from burning iterations on a problem it can't solve.

**Retry differentiation:** Each retry must be meaningfully different from the last. The agent must:
1. Before retrying, review the git diff and test output from the failed attempt
2. Write a one-line diagnosis of *why* it failed to `progress.txt`
3. Attempt a *different approach* — not the same code with minor tweaks. If the same test fails with the same error class twice in a row, the third attempt must try a fundamentally different strategy or escalate immediately.

### One Bead Per Iteration — Hard Rule
Kill the agent after completing each bead and start a fresh one. The agent must **never** pick up a second bead in the same session. Short sessions = cheaper, better decisions, no context rot. `ralph.sh` enforces this by scanning for the `BEAD_DONE` signal and spawning a new agent for the next iteration.

---

## Phase 4: Holistic Review

After all quartets are complete, run a **cross-cutting review** across the finished work. The per-story triads already caught story-level issues — this phase catches concerns that span stories.

Review dimensions (run in parallel where possible):
- **Security** — Auth, injection, secrets exposure, input validation
- **Performance** — N+1 queries, unnecessary allocations, missing caching, algorithmic complexity
- **Architecture** — Coupling, cohesion, separation of concerns, dependency direction
- **Simplicity** — Dead code, over-abstraction, unnecessary indirection across the full codebase
- **Domain-specific** — Whatever concerns are unique to this project's domain

Classify every finding:
- **P1** — Must fix before shipping. Fix immediately.
- **P2** — Should fix soon. File a bead for it: `bd create "P2: [finding]" -p 1`
- **P3** — Nice to fix. Note it in `progress.txt`.

---

## Phase 5: Final Compound

The per-story compound beads captured story-level learnings. This phase captures **project-level** learnings:

1. **Capture** — What worked about the overall process? What didn't? What would you change for the next project?
2. **Update** — Finalize `CLAUDE.md`. Remove rules now enforced by code (tests, linters, type system, CI gates, pre-commit hooks). Review `docs/skills/` for accuracy — prune stale skill files, consolidate overlapping ones.
3. **Regression suite review** — Verify `tests/regression/` covers every bug class found during the project. For each class of bug found: would the system catch it automatically next time? If not, add a regression test, lint rule, hook, or contract. Ensure the regression suite is wired into CI/pre-push (it does not run in every bead iteration gate, only on CI/pre-push).
4. **Update the initializer** — If the project revealed improvements to this workflow, propose updates to `project-kickoff-prompt.md` for the next project.

---

## Standing Rules

- Never guess. If you're unsure, ask me.
- Never make changes outside the current bead's declared scope. The pre-commit hook enforces this, but respect it proactively — don't rely on the hook to catch you.
- Always show me what you are about to do before doing it on anything non-trivial.
- Update `docs/user-guide.md` whenever user-facing behavior changes.
- Run `bd doctor` periodically to keep the beads database healthy.
- `CLAUDE.md` is the constitution (core rules + learned patterns). `docs/skills/` holds domain-specific knowledge. The PRD is the contract. Beads are the work queue. All four must agree.
- **Dependency validation is mandatory.** Every verification gate run includes dep-hallucinator (or equivalent registry check). Never install a package without confirming it exists in its registry and is not a known typosquat. When adding a new dependency, verify: (1) the package exists in the registry, (2) it has meaningful download history, (3) it matches what was intended (not a near-name). Pin exact versions in lockfiles.
- **Enforce constraints structurally, not just verbally.** If a rule matters, it should have a hook, a test, or a gate that enforces it — not just a line in the prompt. When adding a new standing rule, ask: "Can this be enforced by a tool?" If yes, implement the enforcement and note it here. Prompt-level guidance supplements structural enforcement; it does not replace it.
- **Use the right search tool.** Grep/ripgrep for exact string matches. Semantic search for conceptual queries (find code that handles authentication, what is similar to this function). Don't waste context on grep results when the query is conceptual, and don't pay vector search latency for exact lookups.
