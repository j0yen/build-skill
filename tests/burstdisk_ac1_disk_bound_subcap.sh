#!/usr/bin/env bash
# burstdisk_ac1_disk_bound_subcap.sh — PRD-build-burst-remote-disk-guard AC1.
#
# Given a fake box reporting avail_gb=59 nproc=16 free_disk_gb=200, When
# `burst-lane.sh sub-cap` runs with defaults, Then the journal line reads
# sub-cap=2 (avail_gb=59 nproc=16 free_disk_gb=200) bound=disk and stdout
# carries sub-cap=2.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstdisk AC1: sub-cap is disk-bound at 2 on a 59GB/16-core/200GB-disk box" \
  "ok  burstdisk AC1: stdout names the binding term" \
  "ok  burstdisk AC1: journal carries free_disk_gb and bound=disk"
