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

# Single source of truth for bead id shape. Mirrors BEAD_ID_REGEX in
# scripts/ralph/lib.sh. Kept in sync by tests/hooks/parsers.bats (smoke
# test: both files define the same value).
# shellcheck disable=SC2034  # read by callers after sourcing (see ralph.bats)
PARSERS_BEAD_ID_REGEX='[a-z][-a-z0-9]*-[a-z0-9]{2,}'

# bd_bead_in_progress
#
# Print the id of the currently in-progress bead (if any), or empty if none.
# Returns 0 on success (including the no-bead case), 1 if `bd` itself
# failed or returned non-parseable JSON. Callers in a fail-closed chain
# should check the exit code and BLOCK on non-zero, not just an empty
# stdout — otherwise a silent `bd` failure bypasses the entire gate chain
# that conditions on "is a bead in progress?"
#
# Uses --json throughout so a change in `bd list`'s human-readable TUI
# format cannot silently flip the extraction result. install.sh and
# ralph.sh both use this path (via _ralph_bead_in_progress in ralph.sh
# which wraps the same jq invocation) so the two cannot disagree about
# what "there is an in-progress bead" means.
bd_bead_in_progress() {
  command -v bd >/dev/null 2>&1 || {
    # No bd installed: treat as no-bead (Phase 1 bootstrap). This is the
    # only "empty but OK" path for the hook chain.
    return 0
  }
  local raw
  if ! raw=$(bd list --status=in_progress --json 2>/dev/null); then
    # bd exists but failed: do NOT silently pass. The caller should block.
    echo "bd list --status=in_progress failed" >&2
    return 1
  fi
  # Empty output from bd list --json when no beads match — treat as
  # no-bead. `jq -e` returns non-zero for null/empty so we can't use it
  # here; instead, validate that the output parses as JSON and extract.
  if [ -z "$raw" ]; then
    return 0
  fi
  local id
  if ! id=$(jq -r '.[0].id // empty' <<<"$raw" 2>/dev/null); then
    echo "bd list produced non-parseable JSON" >&2
    return 1
  fi
  printf '%s' "$id"
  return 0
}

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

# file_ref_is_valid <project-root> <path> <staged-newline-separated>
# Returns 0 if the path is a valid register reference: exists on disk, is
# staged for addition, or is gitignored (a documented runtime artifact —
# e.g., scripts/ralph/archive.txt — that will not exist in a fresh checkout
# but is load-bearing by name in the register). Returns 1 otherwise.
#
# The gitignored branch closes a class-bug where fm_file_refs_check passes
# locally (because prior ralph runs created the runtime file) but fails on
# CI / fresh clone. Binds the check to "is this a declared reference" rather
# than to the proxy "does this file happen to exist right now."
file_ref_is_valid() {
  local project_root="$1"
  local file_part="$2"
  local staged="$3"
  [ -f "$project_root/$file_part" ] && return 0
  printf '%s\n' "$staged" | grep -qx "$file_part" && return 0
  if command -v git >/dev/null 2>&1 \
     && git -C "$project_root" check-ignore -q "$file_part" 2>/dev/null; then
    return 0
  fi
  return 1
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
    if ! file_ref_is_valid "$project_root" "$file_part" "$staged"; then
      missing="${missing}
    ${ref}"
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
    if ! file_ref_is_valid "$project_root" "$ref" "$staged"; then
      missing="${missing}
    ${ref}"
    fi
  done < <(grep -oE '(tests?|proofs|src|spec|docs|tasks|scripts|lib|pkg)/[a-zA-Z0-9_/.-]+\.[a-zA-Z0-9]+' "$dec_register" 2>/dev/null | sort -u)

  if [ -n "$missing" ]; then
    printf '%s\n' "$missing"
    return 1
  fi
  return 0
}

# gate_command_extract <claude-md-path>
gate_command_extract() {
  local claude_md="$1"
  [ -f "$claude_md" ] || return 0
  awk '
    /^## Verification Gate[[:space:]]*$/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^```/ { in_fence = !in_fence; next }
    in_section && in_fence { print }
  ' "$claude_md"
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

