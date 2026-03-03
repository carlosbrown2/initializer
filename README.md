# Agent Template

A GitHub repo template for AI-assisted development using the Ralph loop and Compound Engineerinng patterns with [Beads](https://github.com/steveyegge/beads) issue tracking.

`project-kickoff-prompt.md` does the heavy lifting of guiding the agent to build the development infrastructure other agents will use, by interacting with you the user.

## Quick Start

1. Click **"Use this template"** on GitHub to create a new repo from this template.

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

Note: the spec is not automatically generated from a one sentence description. It is an iterative process that requires your creativity and guidance. The more clarity you bring here, the better the outcome.

## What's Included

```
project-kickoff-prompt.md   # The main workflow prompt — paste into your agent
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

### The 5 Phases

1. **Spec** — Discovery, research, approach selection, PRD, backpressure design, tooling setup
2. **Beads** — Break the PRD into dependency-aware implementation beads (quartets: impl, review, pare-down, compound)
3. **Implementation (Ralph Loop)** — Each iteration: fresh agent, one bead, commit, stop. Memory persists via git, CLAUDE.md, skills, and progress.txt
4. **Holistic Review** — Cross-cutting review across all completed work
5. **Final Compound** — Project-level learnings, regression suite review, template updates

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
- **Retry tracking** — 3 failures on the same bead triggers automatic escalation.
- **Progress compaction** — Archives old entries to keep context windows clean.
- **Rate limit detection** — Exits gracefully on API limits.

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

- [The Ralph Loop](https://ghuntley.com/loop/) by Geoff Huntley — the original pattern this template is built around
- [Compound Engineering](https://every.to/source-code/compound-engineering-the-definitive-guide) by Every — the guide to making every unit of AI-assisted work compound into the next

## License

MIT
