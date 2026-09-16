#!/usr/bin/env bash
# multibox_ac14_tripwire_catches_stray_boxes_literal.sh —
# PRD-build-burst-state-keyed-by-server-v2 AC14.
#
# Given a "boxes/" literal added to burst-lane.sh outside box_path() and
# the migration function, When the tripwire runs, Then it fails naming the
# line.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  multibox AC14: tripwire fails on a boxes/ literal outside the allowed block" \
  "ok  multibox AC14: tripwire names the offending line"
