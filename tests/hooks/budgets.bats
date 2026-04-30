#!/usr/bin/env bats
# tests/hooks/budgets.bats — harness implementation-surface caps.
#
# Cross-cutting invariant #4 from docs/upstream-harness-improvements.md
# § 2026-04-29: the four shell files that make up the harness
# (scripts/ralph/ralph.sh, scripts/ralph/lib.sh, scripts/hooks/parsers.sh,
# scripts/hooks/install.sh) carry per-file line caps and a single
# per-function size cap. Both fire at commit via the `bats tests/hooks/`
# clause already in the verification gate, so gate-clause count stays
# fixed (cross-cutting invariant #2).
#
# Cap-raise discipline. A failing cap is a structural trigger for a
# `harness-pare:` bead. The bead's DoD:
#   1. List every function in the over-budget file.
#   2. Name each function's binding test or contract (CLAUDE.md's
#      "Pare-down test: where is the bound?" pattern, applied to
#      harness code).
#   3. Classify each as ritual (no bind) or load-bearing (bound).
#   4. Pare ritual until under budget. If no ritual exists, refactor
#      a load-bearing function into smaller helpers. If both fail,
#      raise the cap with documented justification in the bead's notes.
# Caps are never raised silently — every raise is signal for the next
# template-side back-port review.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "scripts/ralph/ralph.sh under per-file line cap (600)" {
  # Cap raised 550 → 600 by agent-template-ebh: the runaway-loop entry's
  # Change 4 (governance-bead surfacing + >7d force-LOW) added the
  # _ralph_surface_stale_governance helper, the per-iter bd-list snapshot,
  # and the post-compute_confidence override. The prior cap was calibrated
  # at 549 (zero headroom) so even a single-feature add forces the raise;
  # documented per the cap-raise discipline above. Future raises pair the
  # increment with the bead notes in scripts/ralph/archive.txt.
  count=$(wc -l < "$PROJECT_ROOT/scripts/ralph/ralph.sh")
  [ "$count" -le 600 ]
}

@test "scripts/ralph/lib.sh under per-file line cap (400)" {
  count=$(wc -l < "$PROJECT_ROOT/scripts/ralph/lib.sh")
  [ "$count" -le 400 ]
}

@test "scripts/hooks/parsers.sh under per-file line cap (600)" {
  count=$(wc -l < "$PROJECT_ROOT/scripts/hooks/parsers.sh")
  [ "$count" -le 600 ]
}

@test "scripts/hooks/install.sh under per-file line cap (700)" {
  count=$(wc -l < "$PROJECT_ROOT/scripts/hooks/install.sh")
  [ "$count" -le 700 ]
}

@test "no harness shell function exceeds per-function size cap (60 lines)" {
  # Walks each top-level function definition (`name() {` at column 0)
  # to its closing `}` at column 0 and computes the block length.
  # Reports the longest function across all four harness files. Cap
  # chosen at largest current function (rubric_edit_check, 46) plus
  # modest headroom; the next add — not the current state — should
  # trigger the harness-pare review.
  result=$(awk '
    FNR == 1 { in_fn = 0 }
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{[[:space:]]*$/ {
      name = $0
      sub(/\(\).*/, "", name)
      start = FNR
      in_fn = 1
      next
    }
    in_fn && /^\}[[:space:]]*$/ {
      len = FNR - start + 1
      if (len > max_len) {
        max_len = len
        max_loc = FILENAME ":" name
      }
      in_fn = 0
    }
    END { print max_len " " max_loc }
  ' \
    "$PROJECT_ROOT/scripts/ralph/ralph.sh" \
    "$PROJECT_ROOT/scripts/ralph/lib.sh" \
    "$PROJECT_ROOT/scripts/hooks/parsers.sh" \
    "$PROJECT_ROOT/scripts/hooks/install.sh")
  max_len=$(echo "$result" | awk '{print $1}')
  max_loc=$(echo "$result" | awk '{print $2}')
  if [ -n "$max_len" ] && [ "$max_len" -gt 60 ]; then
    echo "Largest harness function: $max_loc ($max_len lines, cap=60)" >&2
    echo "Trigger a harness-pare bead per docs/upstream-harness-improvements.md § 2026-04-29." >&2
    return 1
  fi
}
