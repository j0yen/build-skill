#!/usr/bin/env bash
# reality_ac11_alarm_fires_once_no_repeat.sh —
# PRD-build-post-ship-reality-check AC11.
#
# Given a box-only AC pending 6h with no boot window, When the deadline
# passes, Then exactly one alarm fires naming the ship and AC, and no
# second alarm repeats for the same pending state.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/reality-check-ac-common.sh"
run_reality_suite_and_expect_labels \
  "ok  AC11: first alarm-check fires exactly one alarm naming the ship+AC" \
  "ok  AC11: the registration is marked alarmed so it can't fire twice" \
  "ok  AC11: second alarm-check (real failure-mode case: same pending state again) emits no new alarm" \
  "ok  AC11: journal gained exactly one alarm line, not two"
