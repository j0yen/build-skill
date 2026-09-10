#!/usr/bin/env bash
# burstdisk_ac8_selftest_reports_new_cases_by_name.sh — PRD-build-burst-remote-disk-guard AC8.
#
# Given the selftest fixture set, When `burst-lane-selftest.sh` runs,
# Then it exits 0 and reports the new `burstdisk` cases by name — one
# representative label per AC1-AC7 (the full set is exercised by the
# other tests/burstdisk_ac<N>_*.sh wrappers; this one asserts the suite
# as a whole reports every AC number, not just any one of them).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstdisk AC1: sub-cap is disk-bound at 2 on a 59GB/16-core/200GB-disk box" \
  "ok  burstdisk AC2: run exits 3 below the disk floor" \
  "ok  burstdisk AC3: run exits 3 on a named rsync-up failure" \
  "ok  burstdisk AC4: reap reports exactly one reaped dir" \
  "ok  burstdisk AC5: down still exits 0 despite a failed reap listing" \
  "ok  burstdisk AC6: status --json reports disk_state=low" \
  "ok  burstdisk AC7: rollup line names reaped_dirs, reaped_gb, disk_low_fallbacks"
