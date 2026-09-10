#!/usr/bin/env bash
# burstpull_ac1_consecutive_runs_skip_pull.sh — PRD-build-burst-pull-on-demand AC1.
#
# Given two consecutive remote runs on one worktree in fixture mode, when
# the second completes, then no pull ran between them, the worktree is
# marked dirty, and both attribution rows carry pulls_skipped with an
# estimate flag.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  no pull ran between two consecutive remote runs (AC1)" \
  "ok  worktree still listed dirty after two consecutive runs (AC1)" \
  "ok  both consecutive-run attribution rows carry pulls_skipped + estimate=true (AC1)"
