#!/usr/bin/env python3
"""tick-reconcile.py — dispatch-evidence reconciliation for tick-run.sh
(PRD-build-tick-under-dispatch-ledger requirement 3).

Reads a JSON object from stdin: {"admitted": [{"slug":..., "path":...}, ...]}
(the same admitted[] shape select-tick.sh persists — path is each PRD's own
file). Args: <tick_started_epoch> <state_dir> [<journal_file> ...]

For each admitted slug, dispatched = true iff any of:
  a) state_dir/prd-<slug>.lock.pid or state_dir/prd-<slug>.lock has an
     mtime >= tick_started_epoch (lane-claim.sh's own lock files — no new
     marker, per this PRD's Non-goals).
  b) the PRD file (admitted entry's own "path") has an `iter_log:` line
     carrying an ISO-8601 timestamp >= tick_started_epoch.
  c) one of the journal files has a line whose own ISO-8601 timestamp
     prefix is >= tick_started_epoch, and whose fields (split on 2+ spaces
     after the timestamp) are either `build prd <slug> ...` or
     `<slug> <anything> ...`.

Also scans the same journal files for a coordinator-written
`select-tick  under-dispatched  (...)` line (not `-detail`) with a
timestamp >= tick_started_epoch, to answer "did the coordinator already
say so this tick" — its `cause=` value is extracted if found.

Output JSON on stdout:
  {"dispatched_slugs": [...], "missing_slugs": [...],
   "coordinator_cause": <str-or-null>}
"""
import datetime
import json
import os
import re
import sys

ISO_RE = re.compile(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)')
LINE_RE = re.compile(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s+(.*)$')


def to_epoch(ts):
    try:
        dt = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
        return int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())
    except Exception:
        return None


def lock_evidence(state_dir, slug, tick_started):
    for name in (f"prd-{slug}.lock.pid", f"prd-{slug}.lock"):
        p = os.path.join(state_dir, name)
        try:
            if os.path.getmtime(p) >= tick_started:
                return True
        except OSError:
            continue
    return False


def iter_log_evidence(path, tick_started):
    if not path:
        return False
    try:
        with open(path, errors="replace") as f:
            text = f.read()
    except Exception:
        return False
    for line in text.splitlines():
        if "iter_log" not in line:
            continue
        for ts in ISO_RE.findall(line):
            ep = to_epoch(ts)
            if ep is not None and ep >= tick_started:
                return True
    return False


def journal_lines(journal_files):
    for jf in journal_files:
        try:
            with open(jf, errors="replace") as f:
                for line in f:
                    yield line.rstrip("\n")
        except Exception:
            continue


def journal_evidence(journal_files, slug, tick_started):
    for line in journal_lines(journal_files):
        m = LINE_RE.match(line)
        if not m:
            continue
        ep = to_epoch(m.group(1))
        if ep is None or ep < tick_started:
            continue
        fields = re.split(r' {2,}', m.group(2).strip())
        if not fields:
            continue
        if fields[0] == slug:
            return True
        if len(fields) >= 3 and fields[0] == "build" and fields[1] == "prd" and fields[2] == slug:
            return True
    return False


def coordinator_under_dispatched_cause(journal_files, tick_started):
    cause = None
    for line in journal_lines(journal_files):
        m = LINE_RE.match(line)
        if not m:
            continue
        ep = to_epoch(m.group(1))
        if ep is None or ep < tick_started:
            continue
        rest = m.group(2)
        if "select-tick  under-dispatched  " not in rest and "select-tick  under-dispatched(" not in rest:
            continue
        if "under-dispatched-detail" in rest:
            continue
        cm = re.search(r'cause=([^\s)]+)', rest)
        cause = cm.group(1) if cm else "unknown"
    return cause


def main():
    if len(sys.argv) < 3:
        print("usage: tick-reconcile.py <tick_started_epoch> <state_dir> [<journal_file> ...]", file=sys.stderr)
        return 2
    tick_started = int(sys.argv[1])
    state_dir = sys.argv[2]
    journal_files = sys.argv[3:]

    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception:
        payload = {}
    admitted = payload.get("admitted") or []

    dispatched_slugs = []
    missing_slugs = []
    for entry in admitted:
        slug = entry.get("slug")
        if not slug:
            continue
        path = entry.get("path")
        found = (
            lock_evidence(state_dir, slug, tick_started)
            or iter_log_evidence(path, tick_started)
            or journal_evidence(journal_files, slug, tick_started)
        )
        (dispatched_slugs if found else missing_slugs).append(slug)

    out = {
        "dispatched_slugs": dispatched_slugs,
        "missing_slugs": missing_slugs,
        "coordinator_cause": coordinator_under_dispatched_cause(journal_files, tick_started),
    }
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
