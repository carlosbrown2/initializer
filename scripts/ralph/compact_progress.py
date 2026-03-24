#!/usr/bin/env python3
"""Compact progress.txt — move old entries to archive, keep last N iterations.

Called by ralph.sh before each iteration to prevent progress.txt from growing
unbounded. Triggers on line count (>500) or iteration count (>=10 since last).

Compaction procedure:
1. Preserve the Codebase Patterns section at the top
2. Archive old entries to scripts/ralph/archive.txt
3. Keep the last 10 iteration entries
4. Add a compaction pointer noting what was archived
"""

import argparse
import os
import re
import sys

PROGRESS_LINES_THRESHOLD = 500
ITERATIONS_THRESHOLD = 10
KEEP_ENTRIES = 10


def _parse_progress(content: str) -> tuple[list[str], list[str], str | None, list[list[str]]]:
    """Parse progress.txt into (patterns_section, header_lines, entries).

    Returns:
        patterns_section: lines before "# Ralph Progress Log"
        header_lines: log header lines (excluding old compaction pointers)
        old_pointer_start_date: earliest date from any existing pointer, or None
        entries: list of entry line-lists, each starting with "## YYYY-MM-DD"
    """
    lines = content.splitlines(keepends=True)

    # Find "# Ralph Progress Log"
    log_header_idx = None
    for i, line in enumerate(lines):
        if line.strip().startswith("# Ralph Progress Log"):
            log_header_idx = i
            break

    if log_header_idx is None:
        return lines, [], None, []

    patterns_section = lines[:log_header_idx]
    rest = lines[log_header_idx:]

    # Find all entry start positions (lines matching "## YYYY-MM-DD")
    entry_starts = []
    for i, line in enumerate(rest):
        if re.match(r"^## \d{4}-\d{2}-\d{2}", line.strip()):
            entry_starts.append(i)

    if not entry_starts:
        return patterns_section, rest, None, []

    # Header is from log header to first entry, filter out old compaction pointers
    raw_header = rest[: entry_starts[0]]
    header_lines = []
    in_pointer = False
    old_pointer_start_date = None
    for line in raw_header:
        if "<!-- COMPACTION POINTER:" in line:
            in_pointer = True
            m = re.search(r"\((\d{4}-\d{2}-\d{2})", line)
            if m and old_pointer_start_date is None:
                old_pointer_start_date = m.group(1)
            continue
        if in_pointer:
            if "-->" in line:
                in_pointer = False
            continue
        header_lines.append(line)

    # Split entries
    entries = []
    for idx, start in enumerate(entry_starts):
        end = entry_starts[idx + 1] if idx + 1 < len(entry_starts) else len(rest)
        entries.append(rest[start:end])

    return patterns_section, header_lines, old_pointer_start_date, entries


def compact_progress(
    project_root: str, force: bool = False, iterations_since: int = 0
) -> bool:
    """Compact progress.txt if thresholds are met.

    Returns True if compaction was performed.
    """
    progress_path = os.path.join(project_root, "progress.txt")
    archive_path = os.path.join(project_root, "scripts", "ralph", "archive.txt")

    if not os.path.exists(progress_path):
        return False

    with open(progress_path) as f:
        content = f.read()

    line_count = len(content.splitlines())

    needs = (
        force
        or line_count > PROGRESS_LINES_THRESHOLD
        or iterations_since >= ITERATIONS_THRESHOLD
    )
    if not needs:
        return False

    patterns_section, header_lines, old_pointer_start_date, entries = (
        _parse_progress(content)
    )

    if len(entries) <= KEEP_ENTRIES:
        return False  # Not enough entries to compact

    # Split: archive old entries, keep last N
    archive_entries = entries[:-KEEP_ENTRIES]
    keep_entries = entries[-KEEP_ENTRIES:]

    # Extract date range and bead IDs from archived entries
    all_dates = []
    all_beads = []
    for entry in archive_entries:
        date_m = re.match(r"^## (\d{4}-\d{2}-\d{2})", entry[0].strip())
        if date_m:
            all_dates.append(date_m.group(1))
        bead_m = re.search(r"\w+-\w+", entry[0])
        if bead_m:
            all_beads.append(bead_m.group())

    first_date = old_pointer_start_date or (all_dates[0] if all_dates else "unknown")
    last_date = all_dates[-1] if all_dates else "unknown"
    first_bead = all_beads[0] if all_beads else "unknown"
    last_bead = all_beads[-1] if all_beads else "unknown"

    # Append archived entries to archive.txt
    archive_text = "".join("".join(entry) for entry in archive_entries)
    if archive_text:
        if os.path.exists(archive_path):
            with open(archive_path, "a") as f:
                f.write(archive_text)
        else:
            os.makedirs(os.path.dirname(archive_path), exist_ok=True)
            with open(archive_path, "w") as f:
                f.write("# Ralph Progress Log\n---\n\n" + archive_text)

    # Build compaction pointer
    pointer = (
        f"<!-- COMPACTION POINTER: {len(archive_entries)} iterations "
        f"({first_date} to {last_date}) compacted.\n"
        f"     Full history preserved in: scripts/ralph/archive.txt\n"
        f"     Compacted entries: {first_bead} through {last_bead}\n"
        f"     To restore: copy entries from archive.txt back into this file -->\n"
    )

    # Rebuild progress.txt
    new_content = (
        "".join(patterns_section)
        + "".join(header_lines)
        + "\n"
        + pointer
        + "\n"
        + "".join("".join(entry) for entry in keep_entries)
    )

    # Atomic write (temp + rename)
    tmp_path = progress_path + ".tmp"
    with open(tmp_path, "w") as f:
        f.write(new_content)
    os.replace(tmp_path, progress_path)

    print(f"Compacted: archived {len(archive_entries)} entries, kept {len(keep_entries)}")
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Compact progress.txt")
    parser.add_argument(
        "--project-root",
        default=os.path.dirname(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        ),
    )
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--iterations-since", type=int, default=0)
    args = parser.parse_args()

    result = compact_progress(args.project_root, args.force, args.iterations_since)
    sys.exit(0 if result else 1)
