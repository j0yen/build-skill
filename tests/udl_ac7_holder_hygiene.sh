#!/usr/bin/env bash
# udl_ac7_holder_hygiene.sh —
# PRD-build-tick-under-dispatch-ledger AC7.
#
# Given a healthy tick that exits normally, When the next tick starts,
# Then no `tick-lock  reclaimed` line is journaled; Given a holder file
# whose pid is dead, When the next tick starts, Then `reclaimed` is
# journaled once.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
mkdir -p "$BUILD_STATE_DIR"

fail=0

# ---- Leg 1: two back-to-back healthy ticks, neither ever journals
# `tick-lock  reclaimed` (the holder file is gone by the time the next one
# starts — nothing to reclaim). ----------------------------------------
"$SCRIPT" -- true >/dev/null 2>&1
"$SCRIPT" -- true >/dev/null 2>&1

n=$(grep -cE 'tick-lock  reclaimed' "$TICK_RUN_JOURNAL" 2>/dev/null); n=${n:-0}
if [ "$n" -eq 0 ]; then
  echo "ok  AC7: two healthy back-to-back ticks journal no reclaimed line"
else
  echo "FAIL: expected zero reclaimed lines after healthy ticks, got $n; journal:"
  cat "$TICK_RUN_JOURNAL" 2>/dev/null
  fail=1
fi

if [ -e "$BUILD_STATE_DIR/tick.lock.holder" ]; then
  echo "FAIL: holder file left behind after a healthy exit"
  fail=1
else
  echo "ok  AC7: holder file removed after a healthy exit"
fi

# ---- Leg 2: a holder file whose pid is dead IS reclaimed, once. -------
: > "$TICK_RUN_JOURNAL"
"$SCRIPT" -- sleep 30 &
BGPID=$!
sleep 1
kill -9 "$BGPID" 2>/dev/null
for _ in $(seq 1 50); do
  kill -0 "$BGPID" 2>/dev/null || break
  sleep 0.1
done

"$SCRIPT" -- true >/dev/null 2>&1

n2=$(grep -cE "tick-lock  reclaimed  \(stale_pid=$BGPID\)" "$TICK_RUN_JOURNAL" 2>/dev/null); n2=${n2:-0}
if [ "$n2" -eq 1 ]; then
  echo "ok  AC7: a dead-pid holder is reclaimed exactly once"
else
  echo "FAIL: expected exactly one reclaimed line for stale_pid=$BGPID, got $n2; journal:"
  cat "$TICK_RUN_JOURNAL" 2>/dev/null
  fail=1
fi

exit "$fail"
