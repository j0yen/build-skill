#!/usr/bin/env bash
# pullback_ac11_iteration_log.sh — PRD-build-burst-pull-back-restore AC11.
#
# Given the suite at the commit that ships this PRD, When it runs, Then
# the iteration log records the count of transfer-layer failures found
# after the guard came under suite control and the cause of each.
#
# Implemented: scripts/burst-lane-selftest.sh opens a dedicated "pullback"
# block (block_start "pullback", right after AC1's own floor-control
# section) that every "pullback AC<n>: ..." case (AC3/AC5/AC12 today, and
# any future pullback AC) is attributed to via expect()'s existing
# block_of() naming convention. On every run, right before the final
# PASS/FAIL verdict, the suite appends one JSON line to a durable,
# re-derivable ledger — $HOME/.claude/skills/build/state/
# pullback-transfer-log.jsonl, never the run's own sandboxed
# $BURST_LANE_STATE_DIR — naming the total pullback-block case count, how
# many failed, and (when non-zero) the label of each failing case as its
# cause. This wrapper checks the suite's own "pullback-iteration-log: ..."
# stdout line plus the ledger file itself, rather than re-deriving the
# count independently (the suite's own block counters ARE the source of
# truth this AC asks for).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullback-ac-common.sh"
pullback_run_suite

fail=0

summary_line="$(grep -E '^pullback-iteration-log: ' <<<"$PULLBACK_OUT" | tail -1)"
if [ -n "$summary_line" ]; then
  echo "ok  pullback AC11: suite emitted its own iteration-log summary line: $summary_line"
else
  echo "FAIL pullback AC11: no 'pullback-iteration-log: ...' line in the suite's own run output" >&2
  fail=1
fi

ledger="$HOME/.claude/skills/build/state/pullback-transfer-log.jsonl"
if [ -s "$ledger" ]; then
  echo "ok  pullback AC11: the durable ledger exists and is non-empty ($ledger)"
else
  echo "FAIL pullback AC11: ledger missing or empty: $ledger" >&2
  fail=1
fi

if [ -s "$ledger" ] && tail -1 "$ledger" | python3 -c '
import json, sys
rec = json.loads(sys.stdin.read())
for k in ("ts", "total", "failed", "causes"):
    assert k in rec, f"missing key {k}"
assert isinstance(rec["total"], int) and isinstance(rec["failed"], int)
' 2>/dev/null; then
  echo "ok  pullback AC11: the ledger's last line is well-formed JSON naming total/failed/causes"
else
  echo "FAIL pullback AC11: the ledger's last line is missing or malformed" >&2
  fail=1
fi

if [ -s "$ledger" ]; then
  last_failed="$(tail -1 "$ledger" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["failed"])' 2>/dev/null || echo '?')"
  echo "info pullback AC11: this run's own ledger row reports failed=$last_failed (0 means every pullback-block case, including this PRD's own AC3/AC5/AC12, is green)"
fi

exit $fail
