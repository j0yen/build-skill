#!/usr/bin/env python3
"""decisions-vision-extract.py — pull Joe-owned open questions out of a
vision markdown file for `decisions.sh import-vision`
(PRD-build-open-decision-escalation requirement 7).

Scope decision (smallest reasonable reading — the PRD's own prose,
"parses (Joe, <due>) / (Joe) in Open questions blocks", is a loose
paraphrase; the real file's Open-questions material overwhelmingly uses
markdown tables, `| question | owner | due |`, under `## Open questions`
/ `### Open questions added` headings, not literal parenthetical "(Joe)"
markers — verified against visions/buildloop-operations.md, 09/2026):
this script parses table rows under an Open-questions heading whose
`owner` cell is exactly `Joe`. A row whose question text contains
"RESOLVED" (case-insensitive) is skipped — it is not an open decision
anymore, it is a record of a closed one. Free-prose "(Joe, ...)" /
"— Joe" paragraph markers elsewhere in the file are out of scope for
this pass (documented here, not silently dropped).

Usage: decisions-vision-extract.py <file.md>
Prints one TAB-separated `question<TAB>due` line per candidate row (due
is the raw due-column text; decisions.sh only honors it when it looks
like an ISO date, otherwise the ledger's own 2-day default applies).
"""
import re
import sys

HEADING_RE = re.compile(r"^#{1,6}\s+(.*)$")
OPEN_HEADING_RE = re.compile(r"open questions", re.IGNORECASE)
TABLE_ROW_RE = re.compile(r"^\|(.+)\|(.+)\|(.+)\|\s*$")
SEP_ROW_RE = re.compile(r"^\|[\s:-]+\|[\s:-]+\|[\s:-]+\|\s*$")


def main():
    if len(sys.argv) != 2:
        print("usage: decisions-vision-extract.py <file.md>", file=sys.stderr)
        sys.exit(2)

    with open(sys.argv[1], encoding="utf-8") as f:
        lines = f.readlines()

    active = False
    seen = set()
    for raw in lines:
        line = raw.rstrip("\n")
        m = HEADING_RE.match(line)
        if m:
            active = bool(OPEN_HEADING_RE.search(m.group(1)))
            continue
        if not active:
            continue
        if SEP_ROW_RE.match(line):
            continue
        m = TABLE_ROW_RE.match(line)
        if not m:
            continue
        question, owner, due = (c.strip() for c in m.groups())
        if question.lower() == "question" and owner.lower() == "owner":
            continue  # header row
        if owner != "Joe":
            continue
        if "resolved" in question.lower():
            continue
        if not question or question in seen:
            continue
        seen.add(question)
        # TAB can't appear in markdown table cells (would break the table
        # itself), so a plain tab join is a safe delimiter here.
        print(f"{question}\t{due}")


if __name__ == "__main__":
    main()
