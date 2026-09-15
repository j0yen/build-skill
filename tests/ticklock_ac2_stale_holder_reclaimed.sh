#!/usr/bin/env bash
# ticklock_ac2_stale_holder_reclaimed.sh — PRD-build-tick-lock-held AC2.
#
# Given the first tick-run.sh from AC1 is killed with SIGKILL, When
# tick-run.sh -- true runs, Then it succeeds and journals
# `tick-lock  reclaimed  (stale_pid=<pid>)`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
export TICK_RUN_BOOT_ID_FILE="$TMP/boot-id"
echo "boot-fixture-A" > "$TICK_RUN_BOOT_ID_FILE"
mkdir -p "$BUILD_STATE_DIR"

fail=0

"$SCRIPT" -- sleep 30 &
BGPID=$!
sleep 1
kill -9 "$BGPID" 2>/dev/null
# Wait for the kernel to actually reap the fd (SIGKILL is asynchronous).
for _ in $(seq 1 50); do
  kill -0 "$BGPID" 2>/dev/null || break
  sleep 0.1
done

out="$("$SCRIPT" -- true 2>&1)"
rc=$?

if [ "$rc" -eq 0 ]; then
  echo "ok  AC2: tick-run.sh succeeds after the holder was SIGKILLed"
else
  echo "FAIL: expected rc=0 after stale holder, got rc=$rc (output: $out)"
  fail=1
fi

if grep -qE "tick-lock  reclaimed  \(stale_pid=$BGPID\)" "$TICK_RUN_JOURNAL"; then
  echo "ok  AC2: journal has tick-lock reclaimed (stale_pid=$BGPID)"
else
  echo "FAIL: journal missing reclaimed line; contents:"
  cat "$TICK_RUN_JOURNAL" 2>/dev/null
  fail=1
fi

exit "$fail"
