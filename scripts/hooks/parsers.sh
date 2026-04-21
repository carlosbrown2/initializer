#!/bin/bash
# scripts/hooks/parsers.sh — register-integrity parser library
#
# Functions exposed for callers (the generated .git/hooks/pre-commit script and
# the bats suite under tests/hooks/). Each function:
#   - takes a register/file path as $1 (and project-root + staged-list where needed)
#   - prints offending rows / missing references to stdout
#   - returns 0 on pass, 1 on fail
#
# This file is sourced, not executed. Callers manage their own set -e state.

# fm_status_check <register-path>
fm_status_check() {
  local fm_register="$1"
  local bad
  bad=$(awk '
    /^\|/ {
      line = $0
      stripped = line
      gsub(/[|:\- \t]/, "", stripped)
      if (stripped == "") next
      if (line ~ /Failure mode/ || line ~ /Status[ \t]*\|/) next

      n = split(line, cells, "|")
      last_cell = cells[n-1]
      sub(/^[ \t]+/, "", last_cell)
      sub(/[ \t]+$/, "", last_cell)
      if (last_cell != "covered" && last_cell != "proven-impossible" && last_cell != "out-of-scope") {
        print NR ": " line
      }
    }
  ' "$fm_register" 2>/dev/null) || true

  if [ -n "$bad" ]; then
    printf '%s\n' "$bad"
    return 1
  fi
  return 0
}

# fm_file_refs_check <register-path> <project-root> [<staged-files-newline-separated>]
fm_file_refs_check() {
  local fm_register="$1"
  local project_root="$2"
  local staged="${3:-}"
  local missing=""
  local ref file_part
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    file_part="${ref%%::*}"
    if [ ! -f "$project_root/$file_part" ]; then
      if ! printf '%s\n' "$staged" | grep -qx "$file_part"; then
        missing="${missing}
    ${ref}"
      fi
    fi
  done < <(grep -oE '(tests?|proofs|src|spec|docs|tasks|scripts|lib|pkg)/[a-zA-Z0-9_/.-]+\.[a-zA-Z0-9]+(::[a-zA-Z0-9_]+)?' "$fm_register" 2>/dev/null | sort -u)

  if [ -n "$missing" ]; then
    printf '%s\n' "$missing"
    return 1
  fi
  return 0
}

# dec_required_rows_check <register-path>
dec_required_rows_check() {
  local dec_register="$1"
  local required=(
    "Solution selection"
    "Acceptance interpretation"
    "Sampling variance"
    "Verification truth"
    "Scope creep"
  )
  local missing="" d
  for d in "${required[@]}"; do
    if ! grep -qF "$d" "$dec_register"; then
      missing="${missing}
    ${d}"
    fi
  done
  if [ -n "$missing" ]; then
    printf '%s\n' "$missing"
    return 1
  fi
  return 0
}

# dec_row_structure_check <register-path>
dec_row_structure_check() {
  local dec_register="$1"
  local bad
  bad=$(awk '
    /^\|/ {
      line = $0
      stripped = line
      gsub(/[|:\- \t]/, "", stripped)
      if (stripped == "") next
      if (line ~ /Decision point/) next

      count_line = line
      gsub(/\\\|/, "", count_line)
      n_pipes = gsub(/\|/, "|", count_line)
      if (n_pipes < 6) {
        print NR ": (too few columns) " $0
        next
      }

      n = split(line, cells, "|")
      last_cell = cells[n-1]
      sub(/^[ \t]+/, "", last_cell)
      sub(/[ \t]+$/, "", last_cell)
      if (last_cell != "bounded" && last_cell != "ritual-bounded" && last_cell != "agent-discretion" && last_cell != "escalation-only") {
        print NR ": (bad status) " $0
      }
    }
  ' "$dec_register" 2>/dev/null) || true

  if [ -n "$bad" ]; then
    printf '%s\n' "$bad"
    return 1
  fi
  return 0
}

# dec_file_refs_check <register-path> <project-root> [<staged-files-newline-separated>]
dec_file_refs_check() {
  local dec_register="$1"
  local project_root="$2"
  local staged="${3:-}"
  local missing="" ref
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    if [ ! -f "$project_root/$ref" ]; then
      if ! printf '%s\n' "$staged" | grep -qx "$ref"; then
        missing="${missing}
    ${ref}"
      fi
    fi
  done < <(grep -oE '(tests?|proofs|src|spec|docs|tasks|scripts|lib|pkg)/[a-zA-Z0-9_/.-]+\.[a-zA-Z0-9]+' "$dec_register" 2>/dev/null | sort -u)

  if [ -n "$missing" ]; then
    printf '%s\n' "$missing"
    return 1
  fi
  return 0
}

# Starter rubric constants — used by rubric_edit_check.
# These are the universal starter values that ship in docs/skills/review-rubric.md
# before any project customizes it. The Phase 1 contract is that a project
# (a) replaces the disclaimer, (b) renames the H1 header from the starter, and
# (c) adds at least one clause not in the starter allowlist. The Initializer
# Template's own customization is `P1.hook-bypass` plus the project-named header.
RUBRIC_STARTER_DISCLAIMER="This file is a starter rubric"
RUBRIC_STARTER_HEADER="# Review Severity Rubric"
RUBRIC_STARTER_CLAUSES=(
  "P1.correctness"
  "P1.contract-violation"
  "P1.register-gap"
  "P1.decision-gap"
  "P1.security"
  "P1.data-loss"
  "P1.scope-violation"
  "P1.gate-bypass"
  "P1.test-tautology"
  "P1.flaky-test"
  "P2.weak-test"
  "P2.duplicated-logic"
  "P2.poor-naming"
  "P2.over-abstraction"
  "P2.under-abstraction"
  "P2.missing-error-handling"
  "P2.dependency-bloat"
  "P3.style"
  "P3.docstring-drift"
  "P3.minor-simplification"
  "P3.test-clarity"
)

# rubric_edit_check <rubric-path>
# Returns 0 when the rubric has been customized beyond the shipped starter:
#   - the starter disclaimer phrase is gone,
#   - the first H1 header differs from RUBRIC_STARTER_HEADER verbatim, and
#   - at least one clause exists, with at least one not in RUBRIC_STARTER_CLAUSES.
# Returns 1 otherwise, printing the specific failing reason to stdout. A missing
# rubric file returns 0 (the install.sh guard already conditions on existence).
rubric_edit_check() {
  local rubric="$1"
  [ -f "$rubric" ] || return 0

  if grep -qF "$RUBRIC_STARTER_DISCLAIMER" "$rubric"; then
    echo "starter disclaimer phrase still present (\"$RUBRIC_STARTER_DISCLAIMER\")"
    return 1
  fi

  local header
  header=$(grep -m1 '^# ' "$rubric" | sed -e 's/[[:space:]]*$//')
  if [ "$header" = "$RUBRIC_STARTER_HEADER" ]; then
    echo "H1 header is the starter header verbatim (\"$RUBRIC_STARTER_HEADER\")"
    return 1
  fi

  local clauses
  clauses=$(grep -oE 'P[123]\.[a-z][a-z-]*' "$rubric" 2>/dev/null | sort -u)
  if [ -z "$clauses" ]; then
    echo "no clauses defined (file contains no P1.x / P2.x / P3.x identifiers)"
    return 1
  fi

  local clause starter found_custom=0
  while IFS= read -r clause; do
    [ -z "$clause" ] && continue
    local in_starter=0
    for starter in "${RUBRIC_STARTER_CLAUSES[@]}"; do
      if [ "$clause" = "$starter" ]; then
        in_starter=1
        break
      fi
    done
    if [ "$in_starter" = "0" ]; then
      found_custom=1
      break
    fi
  done <<< "$clauses"

  if [ "$found_custom" = "0" ]; then
    echo "no project-specific clauses (every clause is in the starter allowlist)"
    return 1
  fi

  return 0
}

# rubric_clauses_extract <rubric-path>
# Prints the canonical clause names defined by the rubric (one per line, sorted
# unique). A clause is recognized only when it appears as a bold-marker definition
# (`**P[123].name**`); plain mentions in prose or code fences are ignored, so a
# rubric is the single source of truth for which clauses exist. A missing rubric
# returns 0 with empty output (callers decide how to handle).
rubric_clauses_extract() {
  local rubric="$1"
  [ -f "$rubric" ] || return 0
  grep -oE '\*\*P[123]\.[a-z][a-z-]*\*\*' "$rubric" 2>/dev/null \
    | sed -E 's/\*\*//g' \
    | sort -u
}

# review_artifact_clauses_check <artifact-path> <rubric-path>
# Returns 0 if every clause cited in the artifact (any token matching the
# `P[123].name` shape) is a clause defined in the rubric. Returns 1 with the
# offending clause names on stdout if any cited clause is not in the rubric, or
# if the rubric defines no clauses at all (which would make every citation
# vacuously invalid). This closes the Goodhart hole where the validator only
# checked clause-shape, not membership.
review_artifact_clauses_check() {
  local artifact="$1"
  local rubric="$2"

  local valid_clauses
  valid_clauses=$(rubric_clauses_extract "$rubric")
  if [ -z "$valid_clauses" ]; then
    echo "rubric defines no clauses ($rubric) — cannot validate artifact citations"
    return 1
  fi

  local cited
  cited=$(grep -oE 'P[123]\.[a-z][a-z-]*' "$artifact" 2>/dev/null | sort -u)

  local invented="" clause
  while IFS= read -r clause; do
    [ -z "$clause" ] && continue
    if ! printf '%s\n' "$valid_clauses" | grep -qx "$clause"; then
      invented="${invented}${invented:+
}${clause}"
    fi
  done <<< "$cited"

  if [ -n "$invented" ]; then
    printf '%s\n' "$invented"
    return 1
  fi
  return 0
}

# claude_model_tags_check <claude-md-path>
claude_model_tags_check() {
  local claude_md="$1"
  local bad
  bad=$(awk '
    BEGIN { in_section = 0; current_entry = ""; current_line = 0; has_model = 0 }
    /^## Discovered Patterns/ {
      in_section = 1
      current_entry = ""
      has_model = 0
      next
    }
    in_section && /^## / {
      if (current_entry != "" && !has_model) {
        print current_line ": " current_entry
      }
      in_section = 0
      next
    }
    in_section && /^### / {
      if (current_entry != "" && !has_model) {
        print current_line ": " current_entry
      }
      current_entry = $0
      current_line = NR
      has_model = 0
      next
    }
    in_section && /^[[:space:]]*model:[[:space:]]/ { has_model = 1 }
    END {
      if (in_section && current_entry != "" && !has_model) {
        print current_line ": " current_entry
      }
    }
  ' "$claude_md" 2>/dev/null) || true

  if [ -n "$bad" ]; then
    printf '%s\n' "$bad"
    return 1
  fi
  return 0
}
