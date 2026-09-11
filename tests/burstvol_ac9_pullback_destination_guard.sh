#!/usr/bin/env bash
# burstvol_ac9_pullback_destination_guard.sh —
# PRD-build-burst-persistent-volume AC9.
#
# Given RedBaron free space below the larger of BURST_LOCAL_DISK_FLOOR_GB and the worktree's last observed pull size, when pull runs, then it defers (not an error), journals the deferral with free/need bytes, and leaves the marker dirty.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstvol AC9: pull exits 0 (deferred, not an error)" \
  "ok  burstvol AC9: journal records pull deferred cause=local-disk free_gb=20 need_gb=87" \
  "ok  burstvol AC9: the marker stays dirty (never cleared)"
