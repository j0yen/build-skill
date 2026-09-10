#!/usr/bin/env bash
# pyworktree_ac3_dirty_land_fails_closed.sh — PRD-build-python-worktree-isolation AC3.
#
# Given a python worktree ready to land while the main checkout is dirty
# (simulating an unrelated concurrent mutation), When `land` runs, Then it
# exits non-zero, performs no merge, and the worktree's commits remain
# intact for a retry.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pyworktree-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC3: land on dirty main exits 4" \
  "ok  AC3: dirty land performs no mutation (main HEAD unchanged)" \
  "ok  AC3: dirty land's branch commit remains intact for retry" \
  "ok  AC3: retry after cleaning main lands successfully"
