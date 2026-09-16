#!/usr/bin/env bash
# burst-state-tripwire.sh — PRD-build-burst-state-keyed-by-server-v2
# requirement 10 (completeness tripwire) + requirement 11 (external
# readers). Two independent checks against a burst-lane.sh (real or a
# fixture copy, so this is directly testable — see AC13/AC14):
#
#   1. every literal $STATE_DIR/<first-segment> or
#      $BOX_STATE_DIR/<first-segment> in non-comment code must have
#      <first-segment> listed in the surface file (scripts/burst-
#      state-surface.txt); a name mechanically discovered but not
#      classified fails, naming the path (AC13).
#   2. the literal string "boxes/" must never appear in burst-lane.sh
#      outside the box_path()/box_activate() state-layout block (the
#      contiguous region from the BOX_STATE_DIR= assignment through
#      box_activate()'s closing brace) — AC14.
#
# When gate-wedge.sh / isolation-guard.sh paths are also given, a third
# check (requirement 11 / AC15) fails on any top-level
# "state/burst-lane/locks" or "state/burst-lane/slots" literal in either
# file (the per-box layout means those must only ever be reached via
# boxes/*/locks, boxes/*/slots, or current/...).
#
# Usage: burst-state-tripwire.sh <burst-lane.sh> <surface.txt> [gate-wedge.sh] [isolation-guard.sh]
# Exit 0, silent, on success. Exit 1 with one "tripwire: ..." line per
# violation on failure. Exit 2 on a usage/file-not-found error.
set -uo pipefail

SRC="${1:?usage: burst-state-tripwire.sh <burst-lane.sh> <surface.txt> [gate-wedge.sh] [isolation-guard.sh]}"
SURFACE="${2:?surface.txt required}"
GATE_WEDGE="${3:-}"
ISOLATION_GUARD="${4:-}"

[ -f "$SRC" ] || { echo "tripwire: $SRC not found" >&2; exit 2; }
[ -f "$SURFACE" ] || { echo "tripwire: $SURFACE not found" >&2; exit 2; }

out="$(python3 -c '
import re, sys

src_path, surface_path = sys.argv[1], sys.argv[2]

with open(src_path) as fh:
    lines = fh.readlines()

# ---- locate the box_path()/migration block (the only place "boxes/" may
# appear literally) -----------------------------------------------------
start = end = None
for i, line in enumerate(lines, start=1):
    if start is None and line.startswith("BOX_STATE_DIR="):
        start = i
    if re.match(r"^box_activate\(\)\s*\{", line):
        for j in range(i, len(lines)):
            if lines[j].rstrip("\n") == "}":
                end = j + 1
                break
        break
if start is None:
    start = 1
if end is None:
    end = len(lines)

violations = []

# ---- check 1: "boxes/" literal outside the allowed block --------------
for i, line in enumerate(lines, start=1):
    stripped = line.strip()
    if stripped.startswith("#"):
        continue
    if "boxes/" in line and not (start <= i <= end):
        violations.append("%s:%d: boxes/ literal outside box_path()/migration block (lines %d-%d): %s"
                           % (src_path, i, start, end, stripped))

# ---- check 2: every $STATE_DIR/<name> / $BOX_STATE_DIR/<name> literal
# must be a classified name -----------------------------------------------
known = set()
with open(surface_path) as fh:
    for line in fh:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        known.add(s.split()[0])

# Matches both "$STATE_DIR/name" (direct concatenation) and
# "$STATE_DIR"/name (a separate quoted arg immediately followed by a bare
# /name — e.g. `for f in "$STATE_DIR"/logs/prove.*; do`) so a printf/glob
# call that never literally spells "$STATE_DIR/logs" still gets caught.
pat = re.compile(r"\$(?:BOX_STATE_DIR|STATE_DIR)\"?/([^/\"\x27`)};*\s$]*)")
seen = set()
for i, line in enumerate(lines, start=1):
    stripped = line.strip()
    if stripped.startswith("#"):
        continue
    for m in pat.finditer(line):
        name = m.group(1).rstrip(".")
        if not name:
            continue
        if name not in known and (i, name) not in seen:
            seen.add((i, name))
            violations.append("%s:%d: unclassified state path %r (add it to %s)"
                               % (src_path, i, name, surface_path))

for v in violations:
    print("tripwire: " + v)
sys.exit(1 if violations else 0)
' "$SRC" "$SURFACE")"
rc=$?
[ -n "$out" ] && echo "$out"
fail=$rc

if [ -n "$GATE_WEDGE" ] || [ -n "$ISOLATION_GUARD" ]; then
  for f in "$GATE_WEDGE" "$ISOLATION_GUARD"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    hit="$(grep -nE 'state/burst-lane/(locks|slots)([^/*]|$)' "$f" 2>/dev/null || true)"
    if [ -n "$hit" ]; then
      while IFS= read -r h; do
        echo "tripwire: $f:$h: top-level state/burst-lane/{locks,slots} literal (must scan boxes/*/{locks,slots} or current/...)"
      done <<<"$hit"
      fail=1
    fi
  done
fi

exit "$fail"
