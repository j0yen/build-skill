#!/usr/bin/env bash
# volid_ac7_attached_volume_left_alone.sh — PRD-build-burst-volume-id-
# parse AC7.
#
# Given a volume attached to a live server, when `reap --volumes` runs,
# then it is left alone and not journaled as deleted.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  volidfix AC7: reap --volumes leaves an attached, live volume alone" \
  "ok  volidfix AC7: no volume-deleted line was journaled for the attached volume" \
  "ok  volidfix AC7: the volume still exists in hcloud afterward"
