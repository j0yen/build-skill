#!/usr/bin/env bash
# pyworktree_ac2_solo_roundtrip_unchanged.sh — PRD-build-python-worktree-isolation AC2.
#
# Given one python-extend PRD building alone (no sharing this tick), When
# it completes, Then its final committed state in build_into's main branch
# is identical to today's pre-change behavior (no new artifacts left over,
# no extra wait).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pyworktree-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC1/2: add returns a worktree path" \
  "ok  AC2: solo land exits 0" \
  "ok  AC2: solo land's change is now on main" \
  "ok  AC2: solo land leaves no worktree behind"
