# Initializer

A GitHub repo template that acts as an **initializer agent** — it sets up the development infrastructure, environment, and project scaffolding that subsequent coding agents will use. Built on the Ralph loop and Compound Engineering patterns with [Beads](https://github.com/steveyegge/beads) issue tracking.

Inspired by the [initializer agent pattern](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) from Anthropic's engineering team: a specialized first-session agent that creates the foundation (project rules, dev scripts, progress tracking, verification gates) so every subsequent agent session starts with clean context and clear direction.

`project-kickoff-prompt.md` does the heavy lifting of guiding the agent through this initialization, interacting with you the user to make all key decisions upfront.

Your creativity and thought are needed to use Initializer properly. You wouldn't want it any other way.

## Quick Start

1. Click **"Use this template"** on GitHub to create a new repo from Initializer.

2. Install dependencies:
   ```bash
   # Beads CLI (issue tracking)
   brew install beads          # or: npm install -g @beads/bd
   bd init

   # Pre-commit hooks (optional but recommended)
   ./scripts/hooks/install.sh

   # Dependency hallucination detection (optional)
   pip install dep-hallucinator   # or: npm install -g dep-hallucinator
   ```

3. Direct your agent to walk through `project-kickoff-prompt.md`. It guides the agent through the full workflow: spec (PRD), beads, implementation, and review.

## What's Included

```
project-kickoff-prompt.md   # The initializer — guides the agent through full project setup
CLAUDE.md                   # Skeleton project rules (filled in during Phase 1)
progress.txt                # Running log with cross-session pattern transfer
scripts/
  ralph/
    ralph.sh                # The Ralph loop — runs agents one bead at a time
    prompt.md               # Per-iteration agent instructions
    patterns.md             # Codebase patterns discovered during implementation
    compact_progress.py     # Automatic progress.txt compaction
  hooks/
    install.sh              # Pre-commit hook installer (scope, size, deps)
docs/
  skills/                   # Domain-specific knowledge (loaded per-bead)
  reviews/                  # Review artifacts (created/deleted during triads)
tasks/                      # PRDs live here
tests/
  regression/               # Regression tests from bugs found during the project
```

## How It Works

The initializer walks you through 5 phases. Phase 1 is the core initialization — it produces all the artifacts subsequent agents need. Phases 2-5 handle planning and execution.

### The 5 Phases

1. **Spec (Initialization)** — Discovery, research, approach selection, PRD, backpressure design, tooling setup
2. **Beads** — Break the PRD into dependency-aware implementation beads (quartets: impl, review, pare-down, compound)
3. **Implementation (Ralph Loop)** — Each iteration: fresh agent, one bead, commit, stop. Memory persists via git, CLAUDE.md, skills, and progress.txt
4. **Holistic Review** — Cross-cutting review across all completed work
5. **Final Compound** — Project-level learnings, regression suite review, Initializer updates

### The Ralph Loop

`ralph.sh` runs a loop where each iteration spawns a fresh agent that completes exactly one bead:

```bash
# Run with Claude Code (default)
source scripts/ralph/ralph.sh

# Run with Amp
source scripts/ralph/ralph.sh --tool amp

# Limit iterations
source scripts/ralph/ralph.sh 50
source scripts/ralph/ralph.sh --tool amp 50
```

Features:
- **Confidence routing** — HIGH confidence + green gate = auto-land. MEDIUM/LOW pause for review.
- **Structured exit states** — `BLOCKED` auto-files blockers, `REWORK_REQUIRED` re-opens prerequisite beads. Both unclaim and proceed.
- **Retry tracking** — 3 failures on the same bead triggers automatic escalation.
- **Progress compaction** — Archives old entries to keep context windows clean.
- **Rate limit detection** — Exits gracefully on API limits.
- **Commit format validation** — commit-msg hook enforces `<type>: [ID] - <title>` convention.
- **Review write protection** — Pre-commit hook blocks source changes during review beads.

### Dependency Hallucination Detection

The kickoff prompt mandates validating all new dependencies against their package registries. This prevents installing AI-hallucinated packages that don't exist or are typosquat targets.

To enable:
1. Install: `pip install dep-hallucinator` (or equivalent for your ecosystem)
2. Add to your verification gate in `CLAUDE.md`
3. Uncomment the dep-hallucinator section in `scripts/hooks/install.sh` and re-run it

If `dep-hallucinator` is unavailable for your ecosystem, substitute with manual registry checks (`pip index versions <pkg>`, `npm view <pkg>`, etc.).

## Configuration

- **Auto-land policy** — Set in `CLAUDE.md` under `## Confidence Routing`. Options: `all`, `high` (default in ralph.sh), `none`.
- **CLAUDE.md size limit** — Default 200 lines, enforced by pre-commit hook. Overflow goes to `docs/skills/`.
- **Max retries** — Default 3, set in `ralph.sh` (`MAX_RETRIES`).
- **Max iterations** — Default 30, passed as argument to `ralph.sh`.

## Credits

- [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) by Anthropic Engineering — the initializer agent pattern and shift-handoff philosophy that inspired this project's name and structure
- [The Ralph Loop](https://ghuntley.com/loop/) by Geoff Huntley — the original loop pattern Initializer is built around
- [Compound Engineering](https://every.to/source-code/compound-engineering-the-definitive-guide) by Every — the guide to making every unit of AI-assisted work compound into the next

## License

MIT
