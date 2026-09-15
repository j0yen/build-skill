#!/usr/bin/env bash
# ticklock_ac5_status_reports_holder_and_free.sh — PRD-build-tick-lock-held AC5.
#
# Given a running tick-run.sh, When tick-run.sh --status runs, Then it
# prints the holder pid, age, and cmdline; after it exits, --status prints
# `free`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"

TMP="$(mktemp -d)"
trap 'kill "${BGPID:-0}" 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
mkdir -p "$BUILD_STATE_DIR"

fail=0

"$SCRIPT" -- sleep 5 &
BGPID=$!
sleep 1

out="$("$SCRIPT" --status)"
if printf '%s' "$out" | grep -qE "pid=$BGPID age=[0-9]+s cmd=sleep 5"; then
  echo "ok  AC5: --status prints holder pid/age/cmdline while held"
else
  echo "FAIL: --status output unexpected: $out"
  fail=1
fi

wait "$BGPID" 2>/dev/null
out2="$("$SCRIPT" --status)"
if [ "$out2" = "free" ]; then
  echo "ok  AC5: --status prints free after the holder exits"
else
  echo "FAIL: --status after exit expected 'free', got: $out2"
  fail=1
fi

exit "$fail"
