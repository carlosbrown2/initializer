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

# register_symbol_refs_check <register-path> <project-root>
#
# For every <path>::<symbol> token in the register, asserts <symbol> is
# defined in <path> as one of: 'def <symbol>(', 'async def <symbol>(',
# 'class <symbol>(' / 'class <symbol>:', module-level '<symbol> = ...', or
# annotated module-level '<symbol>: <type>'. Returns 0 if every cited symbol
# resolves, 1 with a list of every dangling ref otherwise.
#
# Skips refs whose file is missing on disk (delegated to fm_file_refs_check
# / dec_file_refs_check — composability rather than overlap) and refs whose
# file is gitignored (no checked-in source to grep against).
#
# Closes the layer below file-refs-check: a register row that cites
# tests/test_X.py::test_Y silently breaks its bind when a pare-down deletes
# or renames test_Y while file-existence still holds. Substring impostors
# are rejected because each accepted form requires SYMBOL be followed by a
# specific delimiter ('(', ':', '=', or whitespace+':'), which a longer
# identifier (test_boom_extended vs test_boom) cannot satisfy.
register_symbol_refs_check() {
  local register="$1"
  local project_root="$2"
  local missing=""
  local ref file_part symbol_part full_path

  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    case "$ref" in *::*) ;; *) continue ;; esac
    file_part="${ref%%::*}"
    symbol_part="${ref#*::}"
    full_path="$project_root/$file_part"

    [ -f "$full_path" ] || continue

    if command -v git >/dev/null 2>&1 \
       && git -C "$project_root" check-ignore -q "$file_part" 2>/dev/null; then
      continue
    fi

    if ! grep -qE "^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+${symbol_part}[[:space:]]*\(" "$full_path" 2>/dev/null \
       && ! grep -qE "^[[:space:]]*class[[:space:]]+${symbol_part}[[:space:]]*[(:]" "$full_path" 2>/dev/null \
       && ! grep -qE "^${symbol_part}[[:space:]]*=" "$full_path" 2>/dev/null \
       && ! grep -qE "^${symbol_part}[[:space:]]*:[[:space:]]" "$full_path" 2>/dev/null; then
      missing="${missing}
    ${ref}"
    fi
  done < <(grep -oE '(tests?|proofs|src|spec|docs|tasks|scripts|lib|pkg)/[a-zA-Z0-9_/.-]+\.[a-zA-Z0-9]+::[a-zA-Z0-9_]+' "$register" 2>/dev/null | sort -u)

  if [ -n "$missing" ]; then
    printf '%s\n' "$missing"
    return 1
  fi
  return 0
}

# Starter rubric constants — used by rubric_edit_check.
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
rubric_clauses_extract() {
  local rubric="$1"
  [ -f "$rubric" ] || return 0
  grep -oE '\*\*P[123]\.[a-z][a-z-]*\*\*' "$rubric" 2>/dev/null \
    | sed -E 's/\*\*//g' \
    | sort -u
}

# review_artifact_clauses_check <artifact-path> <rubric-path>
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

# gate_has_soft_fail_escape <gate-command-string>
#
# Returns 0 if the command contains a trailing soft-fail escape
# (`|| true`, `|| :`, `|| 0`, `|| exit 0`). Returns 1 otherwise.
# Extracted from gate.bats so the same check is available to callers
# that want to pre-validate a proposed gate without a bats suite.
#
# The failure-mode register used to name this bug class "`|| true`" — the
# broader name is "soft-fail escape in a correctness chain" because the
# same structural hole covers `|| :`, `|| 0`, `|| exit 0`, and the bash
# precedence rule that binds the trailer to the whole && chain.
gate_has_soft_fail_escape() {
  local gate_cmd="$1"
  # Strip trailing whitespace via bash parameter expansion (avoids SC2001).
  local trimmed="$gate_cmd"
  while [[ "$trimmed" == *[[:space:]] ]]; do
    trimmed="${trimmed%?}"
  done
  if [[ "$trimmed" =~ \|\|[[:space:]]*(true|:|0|exit[[:space:]]+0)[[:space:]]*$ ]]; then
    return 0
  fi
  return 1
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

# pattern_citation_check <claude-md-path>
#
# For every `### <title>` block under `## Discovered Patterns`, the body must
# contain at least one of three citation forms binding the pattern to a
# checked-in artifact:
#   (a) `<dir>/<path>.<ext>::<symbol>` token (dir in the same canonical set
#       used by fm_file_refs_check / dec_file_refs_check: tests, proofs,
#       src, spec, docs, tasks, scripts, lib, pkg) — pins the pattern to a
#       named symbol that register_symbol_refs_check would resolve if the
#       same token appeared in a register;
#   (b) `tests/...` path reference (with or without an extension) — pins
#       the pattern to a test / fixture file;
#   (c) `docs/failure-modes.md` or `docs/decision-register.md` mention —
#       pins the pattern to a register row.
#
# Without this, the only structural rule on the pattern set is the 200-line
# CLAUDE.md cap (a count bound, not a content bound — bytes can grow 4x while
# line count stays flat). The pare-down test ("where is the bound?") applied
# to ## Discovered Patterns itself.
#
# Section bounds match claude_model_tags_check: ## Discovered Patterns opens
# the section, the next top-level `## ` (or EOF) closes it. Lines outside
# the section are ignored.
pattern_citation_check() {
  local claude_md="$1"
  local bad
  bad=$(awk '
    BEGIN { in_section = 0; current_entry = ""; current_line = 0; has_citation = 0 }
    /^## Discovered Patterns/ {
      in_section = 1
      current_entry = ""
      has_citation = 0
      next
    }
    in_section && /^## / {
      if (current_entry != "" && !has_citation) {
        print current_line ": " current_entry
      }
      in_section = 0
      next
    }
    in_section && /^### / {
      if (current_entry != "" && !has_citation) {
        print current_line ": " current_entry
      }
      current_entry = $0
      current_line = NR
      has_citation = 0
      next
    }
    in_section && /(tests?|proofs|src|spec|docs|tasks|scripts|lib|pkg)\/[a-zA-Z0-9_\/.-]+\.[a-zA-Z0-9]+::[a-zA-Z0-9_]+/ {
      has_citation = 1
    }
    in_section && /(^|[^a-zA-Z0-9_\/.-])tests\/[a-zA-Z0-9_][a-zA-Z0-9_\/.-]*/ {
      has_citation = 1
    }
    in_section && /docs\/(failure-modes|decision-register)\.md/ {
      has_citation = 1
    }
    END {
      if (in_section && current_entry != "" && !has_citation) {
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

# archive_schema_check <archive-path> <confidence-log-path>
#
# For every BEAD_DONE entry in confidence.log that names a real bead
# (bead=<id>, not bead=unknown), there must be a matching archive.txt
# block of the form:
#   ## <date-prefix> - <bead-id>
# where <date-prefix> is a YYYY-MM-DD or YYYY-MM-DD HH:MM prefix.
#
# Enforces the prompt.md contract that every successful iteration appends
# a progress entry to archive.txt. Without a mechanical check, archive.txt
# was a proxy for "agent followed the contract" — the prompt said to write
# it, but nothing read it. This check closes that proxy.
#
# Phase 1 bootstrap: if confidence.log is absent, returns 0 (no BEAD_DONEs
# yet to match). If every BEAD_DONE has bead=unknown (the old pre-fix
# state), returns 0 with a stderr note so the Issue is visible but the
# gate does not block — this lets old logs be retired without a full
# archive rewrite.
archive_schema_check() {
  local archive="$1"
  local conflog="$2"

  # No confidence.log: nothing to validate against.
  [ -f "$conflog" ] || return 0
  # No archive.txt: anything that should be there is missing.
  [ -f "$archive" ] || {
    # If confidence.log has no BEAD_DONEs either, Phase 1 bootstrap: pass.
    if ! grep -q 'bead_done=true' "$conflog"; then
      return 0
    fi
    echo "archive.txt is missing but confidence.log records BEAD_DONE iterations"
    return 1
  }

  local missing=""
  local bead_ids
  # Pull all bead_done=true lines with a real bead id (not "unknown"), one
  # id per line, deduplicated.
  bead_ids=$(grep 'bead_done=true' "$conflog" \
    | grep -oE 'bead=[^ ]+' \
    | sed 's/^bead=//' \
    | grep -v '^unknown$' \
    | sort -u) || true

  [ -z "$bead_ids" ] && return 0

  local id
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    # archive.txt block header: "## <date-prefix> - <id>"
    # Require the id at end of line (after " - ") to avoid substring matches.
    if ! grep -qE "^## [0-9]{4}-[0-9]{2}-[0-9]{2}([[:space:]][0-9]{2}:[0-9]{2})? - $id$" "$archive"; then
      missing="${missing}${missing:+
}    $id"
    fi
  done <<< "$bead_ids"

  if [ -n "$missing" ]; then
    printf 'archive.txt missing entry for BEAD_DONE iterations:\n%s\n' "$missing"
    return 1
  fi
  return 0
}
