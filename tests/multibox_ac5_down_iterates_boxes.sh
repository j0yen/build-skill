#!/usr/bin/env bash
# multibox_ac5_down_iterates_boxes.sh — PRD-build-burst-state-keyed-by-
# server-v2 AC5.
#
# Given two boxes, When `down` runs, Then both get a decision line and after
# `down --force` hcloud (fixture) lists no wm-burst-lane* servers and no
# wm-burst-* volumes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  multibox AC5: journal has a decision line for box 1" \
  "ok  multibox AC5: journal has a decision line for box 2" \
  "ok  multibox AC5: down --force leaves no wm-burst-lane* server in hcloud" \
  "ok  multibox AC5: down --force leaves no wm-burst-* volume in hcloud"
