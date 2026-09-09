#!/usr/bin/env bash
# burst-lane_ac11_incremental_sync_fewer_bytes.sh — PRD-build-burst-lane-ccx53 AC11.
#
# Given two consecutive run calls on the same worktree, when the second
# finishes, then its journal line shows fewer bytes transferred than the
# first.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  run's journal line records bytes transferred (req 10)" \
  "ok  first run journaled a byte count" \
  "ok  second run journaled a byte count" \
  "ok  second run's journal line shows fewer bytes than the first (AC11)"
