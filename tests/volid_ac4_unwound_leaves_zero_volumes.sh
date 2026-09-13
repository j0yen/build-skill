#!/usr/bin/env bash
# volid_ac4_unwound_leaves_zero_volumes.sh — PRD-build-burst-volume-id-
# parse AC4.
#
# Given that same unparseable-create case, when `up` finishes, then the
# fake hcloud holds zero volumes for this name and the lane has booted on
# the root disk (volume_mounted=false).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  volidfix AC3/4: up still exits 0, booting on root disk" \
  "ok  volidfix AC4: the fake hcloud holds zero volumes for this name afterward" \
  "ok  volidfix AC4: volume.json records volume_mounted=false (booted on root disk)"
