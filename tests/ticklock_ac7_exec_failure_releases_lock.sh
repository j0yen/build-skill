#!/usr/bin/env bash
# ticklock_ac7_exec_failure_releases_lock.sh — PRD-build-tick-lock-held AC7
# (the failure-path half: "one case asserts the failure path where exec of
# the coordinator fails (missing binary): the lock is released and the
# exit code is the exec failure's, not 0").
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
mkdir -p "$BUILD_STATE_DIR"

fail=0

out="$("$SCRIPT" -- /no/such/binary-does-not-exist-xyz 2>&1)"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "ok  AC7: exec-failure exit code is non-zero ($rc), not 0"
else
  echo "FAIL: exec-failure exit code was 0 (output: $out)"
  fail=1
fi

status_out="$("$SCRIPT" --status)"
if [ "$status_out" = "free" ]; then
  echo "ok  AC7: lock is free after the exec failure (fd closed with the process)"
else
  echo "FAIL: lock not free after exec failure: $status_out"
  fail=1
fi

# A second, genuinely runnable launch must succeed immediately — proof the
# failed exec left nothing wedged.
"$SCRIPT" -- true
rc2=$?
if [ "$rc2" -eq 0 ]; then
  echo "ok  AC7: a subsequent real launch acquires the lock cleanly"
else
  echo "FAIL: subsequent launch after exec failure got rc=$rc2"
  fail=1
fi

exit "$fail"
