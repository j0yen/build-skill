#!/usr/bin/env bash
# pyworktree_ac4_concurrent_writers_no_clobber.sh — PRD-build-python-worktree-isolation AC4.
#
# Given the selftest launching two concurrent fixture python writes against
# one shared build_into, When both complete, Then neither's receipts/diff
# shows any hunk or file from the other, and both land in sequence with a
# clean final `git log --graph`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pyworktree-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC4: X's edit not visible in Y's worktree" \
  "ok  AC4: Y's edit not visible in X's worktree" \
  "ok  AC4: concurrent-x lands (exit 0)" \
  "ok  AC4: concurrent-y lands after rebase-retry (exit 0)" \
  "ok  AC4: both edits present on main, neither clobbered the other" \
  "ok  AC4: final history has no unresolved conflict markers" \
  "ok  AC4: final main checkout is clean"
