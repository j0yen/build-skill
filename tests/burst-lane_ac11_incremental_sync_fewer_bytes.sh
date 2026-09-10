#!/usr/bin/env bash
# burst-lane_ac11_incremental_sync_fewer_bytes.sh — PRD-build-burst-lane-ccx53 AC11.
#
# Given two pulls of the same worktree's target/ separated by a re-dirtying
# run, when the second pull finishes, then its journal line shows fewer
# bytes transferred than the first.
#
# Updated for PRD-build-burst-pull-on-demand: a `run` no longer pulls at
# all (see AC2's wrapper), so "two consecutive runs" no longer produces two
# comparable byte counts — the scenario moved to "two explicit pulls of the
# same worktree, with an intervening run to re-dirty it", which is exactly
# what a real chain looks like now (run...run...pull once, then run again,
# pull again). pull_target_incremental's own rsync mechanics are unchanged
# per the PRD's "Technical considerations" — only the call site moved — so
# the fake rsync's per-destination halving-counter symptom (req 10) still
# proves incremental delta reuse survives the move.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  first explicit pull journaled a byte count (req 10)" \
  "ok  second explicit pull journaled a byte count (req 10)" \
  "ok  second explicit pull's bytes are fewer than the first's (AC11, incremental delta reuse)"
