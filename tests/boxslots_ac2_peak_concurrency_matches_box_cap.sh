#!/usr/bin/env bash
# boxslots_ac2_peak_concurrency_matches_box_cap.sh — PRD-build-burst-run-slots-from-box AC2.
#
# Given that session and BURST_MAX_CONCURRENT_RUNS unset, When 12 fixture
# runs on 12 worktrees start together, Then the peak of concurrently held
# slots (counted from `run routed` journal lines' `concurrent=` field) is 8
# and all 12 complete.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  boxslots AC2: peak concurrently held run slots reaches the box's own cap of 8" \
  "ok  boxslots AC2: all 12 runs complete (12 'run routed' journal lines)" \
  "ok  boxslots AC2: no run exited nonzero"
