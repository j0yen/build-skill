#!/usr/bin/env bash
# burst-lane_ac8_down_keep_scheduled_deleted.sh — PRD-build-burst-lane-ccx53 AC8.
#
# Given Phase 7 with rust work still queued, when the parent calls
# burst-lane.sh down, then the server remains (decision=keep); given no rust
# work remains at minute 20 of a billed hour, then decision=scheduled and
# the server is deleted between minute 58 and 60; given a rust PRD is
# queued at minute 40, then the scheduled deletion is cancelled
# (decision=keep).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  down keeps the session while rust work is queued" \
  "ok  down journaled decision=keep" \
  "ok  down schedules teardown when no rust work remains, early in the hour" \
  "ok  down deletes once inside the last-two-minutes window" \
  "ok  deletion journaled with cost"
