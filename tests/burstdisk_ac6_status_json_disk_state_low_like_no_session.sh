#!/usr/bin/env bash
# burstdisk_ac6_status_json_disk_state_low_like_no_session.sh — PRD-build-burst-remote-disk-guard AC6.
#
# Given `burst-lane.sh status --json`, When free disk is below the floor,
# Then the JSON has "disk_state":"low" and "free_disk_gb" as an integer,
# and `lane-claim.sh target-busy` treats `low` the same as no session.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstdisk AC6: status --json reports disk_state=low" \
  "ok  burstdisk AC6: status --json free_disk_gb is an integer" \
  "ok  burstdisk AC6: sub-cap collapses to 0 (same shape as no-session) when disk is low" \
  "ok  burstdisk AC6: lane-claim.sh effective_subcap treats low disk the same as no session"
