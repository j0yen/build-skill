#!/usr/bin/env bash
# burstvol_ac6_disk_guard_reads_volume_not_root.sh —
# PRD-build-burst-persistent-volume AC6.
#
# Given a mounted volume, when status runs, then the reported disk fields reflect the volume's live df read, not the root disk.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstvol AC6: status --json carries volume.used_pct from a live df read" \
  "ok  burstvol AC6: status (text mode) shows volume=attached 41%"
