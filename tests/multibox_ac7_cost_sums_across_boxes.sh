#!/usr/bin/env bash
# multibox_ac7_cost_sums_across_boxes.sh — PRD-build-burst-state-keyed-by-
# server-v2 AC7.
#
# Given two boxes with costs 0.10 and 0.20 in their ledgers, When
# `cost --today` runs, Then the total is 0.30 and the breakdown lists both
# server_ids and types.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  multibox AC7: cost --today totals 0.30 across both boxes" \
  "ok  multibox AC7: breakdown lists box 1's server_id and type" \
  "ok  multibox AC7: breakdown lists box 2's server_id and type" \
  "ok  multibox AC7: breakdown TOTAL line names both boxes"
