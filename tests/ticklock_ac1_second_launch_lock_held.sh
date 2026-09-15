#!/usr/bin/env bash
# ticklock_ac1_second_launch_lock_held.sh — PRD-build-tick-lock-held AC1.
#
# Given no holder, When `tick-run.sh -- sleep 30 &` starts and a second
# `tick-run.sh -- true` runs within 5s, Then the second exits 75, prints
# `tick-lock-held (pid=<first pid> age=<s> cmd=...)`, and the journal has
# one `build-tick  skip  tick-lock-held` line.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"

TMP="$(mktemp -d)"
trap 'kill "${BGPID:-0}" 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
mkdir -p "$BUILD_STATE_DIR"

fail=0

"$SCRIPT" -- sleep 30 &
BGPID=$!
sleep 1

out="$("$SCRIPT" -- true 2>&1)"
rc=$?

if [ "$rc" -ne 75 ]; then
  echo "FAIL: second launch exit=$rc, want 75 (output: $out)"
  fail=1
else
  echo "ok  AC1: second launch exits 75"
fi

if printf '%s' "$out" | grep -qE "tick-lock-held \(pid=$BGPID age=[0-9]+s cmd="; then
  echo "ok  AC1: second launch names first pid ($BGPID), age, cmd"
else
  echo "FAIL: second launch output missing expected pid/age/cmd shape: $out"
  fail=1
fi

if grep -qE "build-tick  skip  tick-lock-held \(pid=$BGPID" "$TICK_RUN_JOURNAL"; then
  echo "ok  AC1: journal has one build-tick skip tick-lock-held line"
else
  echo "FAIL: journal missing expected line; contents:"
  cat "$TICK_RUN_JOURNAL" 2>/dev/null
  fail=1
fi

lines=$(grep -c "tick-lock-held" "$TICK_RUN_JOURNAL" 2>/dev/null || echo 0)
if [ "$lines" -eq 1 ]; then
  echo "ok  AC1: exactly one tick-lock-held journal line"
else
  echo "FAIL: expected exactly one tick-lock-held line, got $lines"
  fail=1
fi

exit "$fail"
