#!/usr/bin/env bash
# shwt_ac4_dirty_main_exit4.sh — PRD-build-shell-worktree-isolation AC4.
#
# Given a dirty main checkout (one untracked-modified file), When
# `land <repo> s1` runs, Then exit is 4, nothing is mutated, and the
# message names the dirty-main case (existing contract, re-proved after
# the rebase-first change).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/shwt-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC4: land against dirty main exits 4" \
  "ok  AC4: dirty-main message names the case" \
  "ok  AC4: no mutation" \
  "ok  AC4: d1's branch commit remains intact for retry"
