#!/usr/bin/env python3
"""decisions-rows.py — read state/decisions.jsonl and collapse it to the
latest row per id (PRD-build-open-decision-escalation).

state/decisions.jsonl is append-only (Technical considerations): `open`
appends a `status:"open"` row, `close` appends a NEW row with the SAME id
and `status:"closed"` rather than rewriting the file in place, so a later
line for a given id always supersedes an earlier one. This script is the
one place that collapses the log to "current state" — decisions.sh's
open/list/close/nudge subcommands all shell out to it rather than each
re-implementing the same fold.

Usage:
  decisions-rows.py <path> [--status open|closed] [--repo <repo>]

Prints a JSON array to stdout, one object per id (last line wins), each
augmented with:
  age_h    integer hours since opened_ts (None if opened_ts is unparseable)
  overdue  true iff status=="open" and now > due

sorted by opened_ts ascending. A missing file is treated as zero rows
(exit 0, prints `[]`) — decisions.sh callers never need to stat first.
"""
import datetime
import json
import sys


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except ValueError:
        return None


def main():
    if len(sys.argv) < 2:
        print("usage: decisions-rows.py <path> [--status open|closed] [--repo <repo>]", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]
    status_filter = None
    repo_filter = None
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--status" and i + 1 < len(args):
            status_filter = args[i + 1]
            i += 2
        elif args[i] == "--repo" and i + 1 < len(args):
            repo_filter = args[i + 1]
            i += 2
        else:
            i += 1

    rows = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                rid = obj.get("id")
                if not rid:
                    continue
                rows[rid] = obj  # last line for this id wins
    except FileNotFoundError:
        pass

    now = datetime.datetime.now(datetime.timezone.utc)

    out = []
    for rid, obj in rows.items():
        if status_filter is not None and obj.get("status") != status_filter:
            continue
        if repo_filter is not None and obj.get("repo") != repo_filter:
            continue
        opened = parse_ts(obj.get("opened_ts"))
        due = parse_ts(obj.get("due"))
        o = dict(obj)
        o["age_h"] = int((now - opened).total_seconds() // 3600) if opened else None
        o["overdue"] = bool(due and now > due and obj.get("status") == "open")
        out.append(o)

    out.sort(key=lambda r: r.get("opened_ts") or "")
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
