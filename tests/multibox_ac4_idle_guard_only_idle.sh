#!/usr/bin/env bash
# multibox_ac4_idle_guard_only_idle.sh — PRD-build-burst-state-keyed-by-
# server-v2 AC4.
#
# Given one busy box (runs_served=3, rust work remains) and one idle box
# (runs_served=0, age > 900s), When `idle_guard` runs, Then only the idle
# box is deleted and the journal has one decision line per box.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  multibox AC4: the idle box (box 2, runs_served=0) is torn down" \
  "ok  multibox AC4: the busy box (box 1, runs_served=3) is left up in hcloud" \
  "ok  multibox AC4: the idle box is gone from hcloud" \
  "ok  multibox AC4: journal has a decision line for the deleted idle box" \
  "ok  multibox AC4: journal has a decision line for the kept busy box too"
