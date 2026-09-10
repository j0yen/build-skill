#!/usr/bin/env bash
# burstdisk_ac2_run_refuses_below_floor.sh — PRD-build-burst-remote-disk-guard AC2.
#
# Given a fake box reporting free_disk_gb=12, When `burst-lane.sh run
# <worktree> -- cargo build` is invoked, Then no rsync is attempted, exit
# is 3, stdout starts `fallback: disk-low`, and the journal line carries
# cause=disk-low free_gb=12 floor_gb=40.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstdisk AC2: run exits 3 below the disk floor" \
  "ok  burstdisk AC2: stdout starts fallback: disk-low" \
  "ok  burstdisk AC2: journal carries cause=disk-low free_gb=12 floor_gb=40" \
  "ok  burstdisk AC2: no rsync-up was attempted (no new remote dir)"
