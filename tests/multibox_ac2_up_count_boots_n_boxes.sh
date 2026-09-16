#!/usr/bin/env bash
# multibox_ac2_up_count_boots_n_boxes.sh — PRD-build-burst-state-keyed-by-
# server-v2 AC2.
#
# Given BURST_MAX_BOXES=2, When `up --count 2` runs against the fixture
# hcloud, Then two servers wm-burst-lane-1 and wm-burst-lane-2 exist, each
# with its own boxes/<id>/session.json and up.lock, and `current` points to
# the first ready one.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  multibox AC2: up --count 2 exits 0" \
  "ok  multibox AC2: wm-burst-lane-1 exists in hcloud" \
  "ok  multibox AC2: wm-burst-lane-2 exists in hcloud" \
  "ok  multibox AC2: box 1 has its own boxes/<id>/session.json" \
  "ok  multibox AC2: box 2 has its own boxes/<id>/session.json" \
  "ok  multibox AC2: box 1 has its own up.lock" \
  "ok  multibox AC2: box 2 has its own up.lock" \
  "ok  multibox AC2: current points at the first ready box (wm-burst-lane-1)" \
  "ok  multibox AC2: status --json .server_id follows current (box 1)"
