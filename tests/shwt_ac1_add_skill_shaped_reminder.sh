#!/usr/bin/env bash
# shwt_ac1_add_skill_shaped_reminder.sh — PRD-build-shell-worktree-isolation AC1.
#
# Given a fixture skill-shaped repo (SKILL.md + scripts/run-selftests.sh)
# with a clean main, When `worktree-extend.sh add <repo> s1` runs, Then a
# worktree exists under the build-worktrees root on branch autobuilder/s1,
# stderr contains the production-state rule and BUILD_STATE_DIR=<worktree>/
# state, and main is unchanged.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/shwt-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC1: add returns a worktree path under BUILD_WT_ROOT" \
  "ok  AC1: worktree is on branch autobuilder/ac1" \
  "ok  AC1: stderr names the production-state rule" \
  "ok  AC1: stderr names the worktree-local BUILD_STATE_DIR export" \
  "ok  AC1: main checkout unchanged after add"
