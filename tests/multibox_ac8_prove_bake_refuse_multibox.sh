#!/usr/bin/env bash
# multibox_ac8_prove_bake_refuse_multibox.sh — PRD-build-burst-state-keyed-
# by-server-v2 AC8.
#
# Given two boxes, When `prove` runs, Then it refuses with cause=multi-box
# and no box is modified. Requirement 9's own text also covers `bake`
# ("prove and bake operate on the current box only and refuse ...
# cause=multi-box"), so this wrapper checks both.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  multibox AC8: prove refuses with cause=multi-box when two boxes are up" \
  "ok  multibox AC8: journal has 'prove  refused  (cause=multi-box'" \
  "ok  multibox AC8: bake also refuses with cause=multi-box when two boxes are up" \
  "ok  multibox AC8: journal has 'bake  refused  (cause=multi-box'" \
  "ok  multibox AC8: no box was modified (same box set before/after the refused calls)"
