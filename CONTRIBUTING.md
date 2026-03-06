# Contributing

Thanks for your interest in improving Initializer. Contributions are welcome, whether it's fixing a bug in the ralph loop, refining the kickoff prompt, or suggesting new backpressure techniques.

## How to Contribute

1. Fork the repo and create a branch from `main`.
2. Make your changes.
3. Test the ralph loop if your changes touch `ralph.sh`, `ralph.zsh`, or `prompt.md` — create a throwaway bead and run a cycle to verify.
4. Open a pull request with a clear description of what you changed and why.

## What to Contribute

**High-value contributions:**
- Bug fixes in the ralph loop scripts (`ralph.sh`, `ralph.zsh`, `compact_progress.py`)
- Improvements to `prompt.md` agent instructions (clearer bead-type handling, better retry logic)
- New backpressure techniques or pattern sketches in `project-kickoff-prompt.md`
- Pre-commit hook improvements in `scripts/hooks/install.sh`
- Support for additional AI coding tools beyond Claude Code and Amp

**Also welcome:**
- Documentation improvements
- Edge case handling in the loop (signal detection, error recovery)
- CI/CD examples for the template
- Skill file examples in `docs/skills/`

## Guidelines

- Keep changes focused. One concern per PR.
- Test the ralph loop end-to-end if you modify any script. At minimum, verify: bead detection, title display, COMPLETE signal exits the loop, and sourcing doesn't pollute the shell.
- Don't add features to `project-kickoff-prompt.md` that you haven't used in a real project. The prompt should reflect proven workflow, not theoretical improvements.
- Both `ralph.sh` (bash) and `ralph.zsh` (zsh) must stay functionally identical. If you change one, change the other.

## Testing Changes

Create a test bead and run the loop:

```bash
bd init
bd create "test bead" --description "Throwaway bead for testing"

# Test zsh version
source scripts/ralph/ralph.zsh 3

# Test bash version (from a bash shell)
source scripts/ralph/ralph.sh 3
```

Verify:
- The bead ID and title display before the agent runs
- The loop exits cleanly on COMPLETE
- Your shell is not corrupted after the loop finishes (no unset variable errors)

Clean up after testing:

```bash
rm -rf .beads AGENTS.md .pytest_cache
```

## Questions?

Open an issue on GitHub. If you're unsure whether a change fits the project's direction, open an issue to discuss before writing code.
