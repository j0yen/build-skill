#!/usr/bin/env bash
# ticklock_ac4_direct_launch_not_held.sh — PRD-build-tick-lock-held AC4.
#
# Given a fixture coordinator launched directly (not through tick-run.sh),
# When its Phase 0 check runs, Then it journals `phase0 tick-lock-not-held`
# and exits without a `select-tick` line.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
mkdir -p "$BUILD_STATE_DIR"

fail=0

# This is the mechanical stand-in for SKILL.md Phase 0 step 1 itself: a
# coordinator that starts WITHOUT going through tick-run.sh must verify
# (never acquire) and, finding the lock free, journal
# `phase0 tick-lock-not-held` and exit BEFORE ever writing a select-tick
# line.
run_phase0() {
  if "$SCRIPT" --check-held >/dev/null 2>&1; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  build-tick  select-tick  chose-a-prd" >> "$TICK_RUN_JOURNAL"
    return 0
  fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  build-tick  phase0  tick-lock-not-held" >> "$TICK_RUN_JOURNAL"
  return 1
}

# Launched directly — no tick-run.sh ancestor holds the lock, so it must
# be genuinely free.
run_phase0
phase0_rc=$?

if [ "$phase0_rc" -ne 0 ]; then
  echo "ok  AC4: directly-launched fixture's Phase 0 check refuses (rc!=0)"
else
  echo "FAIL: directly-launched fixture's Phase 0 check unexpectedly proceeded"
  fail=1
fi

if grep -q "phase0  tick-lock-not-held" "$TICK_RUN_JOURNAL"; then
  echo "ok  AC4: journal has phase0 tick-lock-not-held"
else
  echo "FAIL: journal missing phase0 tick-lock-not-held; contents:"
  cat "$TICK_RUN_JOURNAL" 2>/dev/null
  fail=1
fi

if grep -q "select-tick" "$TICK_RUN_JOURNAL"; then
  echo "FAIL: journal unexpectedly has a select-tick line"
  fail=1
else
  echo "ok  AC4: journal has no select-tick line"
fi

exit "$fail"
