#!/usr/bin/env bash
# burstdisk_ac7_daily_rollup_names_reap_and_disk_low.sh — PRD-build-burst-remote-disk-guard AC7.
#
# Given a journal day with two reap ok lines totalling 125 GB and one
# disk-low fallback, When the daily rollup fires, Then its line contains
# reaped_dirs=2 reaped_gb=125 disk_low_fallbacks=1.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstdisk AC7: rollup line names reaped_dirs, reaped_gb, disk_low_fallbacks"
