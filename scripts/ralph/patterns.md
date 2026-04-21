## Codebase Patterns

<!-- Add project-specific patterns here as they are discovered during implementation -->

### Extracting a fenced-code-block convention from CLAUDE.md in awk

Use an `in_section` flag that flips on when the target `##` heading is matched
and off when the next `##` heading appears; a separate `in_fence` flag toggles
on every triple-backtick line. Only print lines where both flags are set.
Anchor the heading match with `[[:space:]]*$` so it doesn't match longer
headings that share the prefix. Pattern used by `.git/hooks/pre-push` to
extract the `## Verification Gate` body from `CLAUDE.md`.

### Promoting a decision-register row from ritual-bounded to bounded

When an audit bead lands the enforcement mechanism a row was pending, update
three things in the same commit: (1) the Enforcement cell — name the file
that does the enforcement, because the decision-register integrity hook
validates that any path-shaped token in the register exists on disk; (2) the
Status cell — flip to `bounded`; (3) the "Pending promotions" section below
the table — remove the matching bullet. Missing any of the three leaves the
register internally inconsistent.
