#!/usr/bin/env bash
# shwt_ac9_list_lang_behind_dirty.sh — PRD-build-shell-worktree-isolation AC9 (P1).
#
# Given two worktrees, one 2 commits behind main and dirty, When
# `worktree-extend.sh list` runs, Then its rows show lang=/behind=/dirty=
# per worktree.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/shwt-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC9: l1's row names lang=shell" \
  "ok  AC9: l1's row shows behind=1" \
  "ok  AC9: l1's row shows dirty=no" \
  "ok  AC9: l2's row shows dirty=yes"
