#!/usr/bin/env bash
# shwt_ac7_chain_guard_worktree_isolated.sh — PRD-build-shell-worktree-isolation AC7.
#
# Given chain-guard.sh evaluates a PRD whose work_tree is under the
# build-worktrees root, When it prints its verdict, Then the output carries
# `worktree-isolated: yes`; given a PRD with no worktree, Then
# `worktree-isolated: no`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/shwt-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC7: a PRD whose work_tree is under the worktree root reports worktree-isolated: yes" \
  "ok  AC7: a PRD with no work_tree reports worktree-isolated: no"
