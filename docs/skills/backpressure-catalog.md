# Backpressure Catalog

## When to load

Load this skill when you need a menu of techniques for satisfying a row in `docs/failure-modes.md`. This file is **a reference, not a curriculum** — it lists techniques that have proven useful on prior projects, organized by what they catch and when they fit. Use what fits, ignore what doesn't, and invent better techniques when you can. If you discover one worth keeping, add it back to this file in the project's compound phase.

The contract you're satisfying is *exhaustive coverage of failure modes*, mechanically enforced via the verification gate. The technique is your choice. Bias toward checks that:
- Run in CI on every commit (not "we'll do it later")
- Produce a green/red signal (not a human-readable report nobody reads)
- Are themselves deterministic (a flaky check is worse than no check)

---

## Verification & correctness

Catches bugs before they reach production.

| Technique | What it catches | When to consider |
|-----------|----------------|-----------------|
| **Static typing** (e.g., `mypy --strict`, `tsc --strict`) | Type mismatches, missing annotations, wrong signatures | Always — baseline for any typed language |
| **Unit tests** | Logic errors, regressions, data corruption | Always |
| **Property-based tests** (e.g., Hypothesis, fast-check) | Edge cases no one thought to write tests for; mathematical invariant violations | When code has mathematical invariants, parsers, serialization round-trips, or complex input spaces |
| **Formal verification / SMT** (e.g., Z3, Dafny) | Proves properties hold for ALL inputs, not just sampled ones | When correctness is non-negotiable for specific formulas or mappings (e.g., bounds proofs, injectivity) |
| **Fuzz testing** (e.g., AFL, cargo-fuzz) | Crashes, hangs, and undefined behavior on malformed input | When code processes untrusted or complex input formats |
| **Integration tests** | Failures at component boundaries, API contract violations | When multiple services or modules interact |
| **Schema validation** (e.g., pydantic, JSON Schema, protobuf) | Malformed data crossing boundaries, schema drift between stages | When data flows between stages, services, or systems |
| **Design by contract** (e.g., deal, icontract, dpcontracts) | Pre/postcondition violations, invariant breakage on every call | When functions have non-obvious requirements or guarantees that types alone can't express |
| **Snapshot / golden tests** | Silent regressions in output format, numerical drift | When outputs must be deterministic and stable across changes |
| **Distributional / statistical checks** | Subtle corruption that produces plausible but meaningless statistical results | When code produces probabilistic outputs, p-values, or statistical claims |
| **Static analysis beyond types** (e.g., Bandit, Semgrep, CodeQL, pylint, SonarQube) | Security anti-patterns (hardcoded secrets, injection vectors, unsafe deserialization), excessive complexity, dead code, supply-chain vulnerabilities | Always — types catch structural issues; static analysis catches semantic anti-patterns types can't express |
| **Dependency vulnerability scanning** (e.g., pip-audit, npm audit, Dependabot, Snyk) | Known CVEs in transitive dependencies, outdated packages with security patches | Always — your code may be correct but your dependencies aren't |
| **Dependency hallucination detection** (e.g., dep-hallucinator, manual registry checks) | Packages recommended by AI that don't exist or are typosquat/slopsquat targets | Always — runs in every verification gate pass |
| **Mutation testing** (e.g., mutmut, cosmic-ray for Python; Stryker for JS/TS) | Weak test suites that pass but don't actually catch bugs; tests that assert nothing meaningful | When you need confidence that your test suite is effective, not just green |
| **Browser/E2E automation** (e.g., Puppeteer MCP, Playwright, Cypress) | Visual regressions, broken user flows, client-server integration failures | When the project has a UI — agents can verify features the way a human would, catching issues unit tests miss |

---

## Concurrency & data race prevention

Catches bugs from parallelism and shared state. These are among the hardest bugs to reproduce and easiest to miss.

| Technique | What it catches | When to consider |
|-----------|----------------|-----------------|
| **Race detection** (e.g., Go race detector, ThreadSanitizer, `PYTHONHASHSEED` randomization) | Data races, non-deterministic behavior from unsynchronized shared state | When code uses threads, async, multiprocessing, or shared mutable state |
| **Deadlock detection** (e.g., lock-order analysis, timeout-based acquisition) | Circular lock dependencies, indefinite hangs under contention | When code acquires multiple locks or coordinates between threads |
| **Atomicity guarantees** (e.g., database transactions, file locking, compare-and-swap) | Partial updates visible to concurrent readers, torn writes, lost updates | When multiple writers can modify the same resource, or readers must see consistent state |
| **Deterministic concurrency testing** (e.g., Loom for Rust, systematic schedule exploration) | Bugs that appear only under specific thread interleavings | When correctness depends on ordering of concurrent operations |

---

## Runtime & operational

Catches failures in running systems. These apply primarily to service-oriented architectures; most batch/pipeline projects need only timeouts and idempotency.

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

---

## Pattern sketches for less common techniques

Most agents know how to write unit tests. These sketches show the *shape* of less familiar techniques so you can recognize where they fit and write a project-specific version.

### Property-based test (Hypothesis)

Proves invariants hold across thousands of random inputs:

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

### SMT proof — negation pattern (Z3)

Proves a property holds for ALL inputs by showing no counterexample exists:

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

### SMT — covering array generation (Z3)

Generates minimal test suites covering all pairwise (or t-wise) parameter interactions:

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

### SMT — model-based test data (Z3)

Generates concrete inputs satisfying complex constraints from a spec:

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

### Mutation testing

Tests that test your tests:

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

### Concurrency safety check

Catches races and non-determinism from parallelism:

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

### Distributional check

Catches statistical bugs that produce plausible but wrong results:

```python
def test_null_distribution_not_degenerate(null_values: list[float]) -> None:
    """Null distribution must have variance — otherwise the metric ignores permutation."""
    assert np.std(null_values) > 1e-8, "Null has zero variance; metric is insensitive"
    first_half = np.mean(null_values[: len(null_values) // 2])
    second_half = np.mean(null_values[len(null_values) // 2 :])
    assert abs(first_half - second_half) < 3 * np.std(null_values) / np.sqrt(len(null_values))
```

Use when: code produces p-values, confidence intervals, or any statistical claim. These checks catch silent corruption that passes all other tests.
