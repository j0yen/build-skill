#!/usr/bin/env bash
# pyworktree_ac1_worktree_isolated_until_land.sh — PRD-build-python-worktree-isolation AC1.
#
# Given two python-agent PRDs claimed by the same lane against the same
# build_into, When both run Phase-4 writes in the same tick, Then each
# writes into its own private worktree and `git diff` in the main checkout
# shows zero changes from either until a `land` step runs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pyworktree-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC1/2: add returns a worktree path" \
  "ok  AC1: main checkout clean immediately after add" \
  "ok  AC1: worktree edit invisible in main checkout before land" \
  "ok  AC1: two branches get two distinct worktree paths" \
  "ok  AC1: main checkout still shows zero changes from either"
