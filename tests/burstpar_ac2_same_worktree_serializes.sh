#!/usr/bin/env bash
# burstpar_ac2_same_worktree_serializes.sh — PRD-build-burst-parallel-runs AC2.
#
# Given two runs against the SAME worktree, when launched together, then the
# second starts only after the first's pull-back completes (no overlap).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burstpar-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC2: same-worktree runs never overlap (peak=1 of 2)"
