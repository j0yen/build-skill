#!/usr/bin/env bash
# burstpar_ac1_different_worktrees_overlap.sh — PRD-build-burst-parallel-runs AC1.
#
# Given runs against different fixture worktrees, when launched together,
# then they execute overlapping in time (journal/span timestamps interleave)
# and all exit 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burstpar-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC1: all 12 runs exit 0" \
  "ok  AC1: different-worktree runs overlap in time (peak=4 of 12)"
