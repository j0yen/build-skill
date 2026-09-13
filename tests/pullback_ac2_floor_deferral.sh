#!/usr/bin/env bash
# pullback_ac2_floor_deferral.sh — PRD-build-burst-pull-back-restore AC2.
#
# Given a fixture with the floor raised above free space, When an explicit
# `pull` runs, Then it prints `deferred`, leaves the marker dirty, exits 0,
# and journals no byte count.
#
# Matches scripts/burst-lane-selftest.sh's "burstvol AC9" block (~line
# 3260): BURST_LANE_LOCAL_FREE_GB=20 with a preset 87 GB last-pull-size
# forces need_gb=87 > free_gb=20, deferring the pull.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullback-ac-common.sh"
pullback_run_suite

fail=0
for line in \
  "ok  burstvol AC9: pull exits 0 (deferred, not an error)" \
  "ok  burstvol AC9: journal records pull deferred cause=local-disk free_gb=20 need_gb=87" \
  "ok  burstvol AC9: the marker stays dirty (never cleared)" \
  "ok  burstpull AC3c: deferred pull's stdout never claims 'pulled'" \
; do
  if grep -qF "$line" <<<"$PULLBACK_OUT"; then
    echo "$line"
  else
    echo "FAIL pullback AC2: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
