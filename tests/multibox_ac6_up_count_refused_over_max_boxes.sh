#!/usr/bin/env bash
# multibox_ac6_up_count_refused_over_max_boxes.sh — PRD-build-burst-state-
# keyed-by-server-v2 AC6.
#
# Given BURST_MAX_BOXES=1, When `up --count 2` runs, Then it exits non-zero
# with `up  refused  (cause=max-boxes)` and one box at most exists.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  multibox AC6: up --count 2 exits non-zero under BURST_MAX_BOXES=1" \
  "ok  multibox AC6: journal has 'up  refused  (cause=max-boxes'" \
  "ok  multibox AC6: no box was created (refused before any hcloud call)" \
  "ok  multibox AC6: no server create call was ever made" \
  "ok  multibox AC6: BURST_MAX_BOXES=1 (default) still allows an uncapped single-box up"
