#!/usr/bin/env bash
# bdrift_ac7_warm_pull_zero_bytes_explains_itself.sh —
# PRD-build-burst-selftest-drift-and-bake-gate AC7.
#
# Given a fixture prove on a worktree whose previous pull already matched
# the remote target, When it fails with pull-zero-bytes, Then the journal
# line contains "warm worktree" and "omit --worktree" (requirement 5).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  bakegate AC7: prove exits 1 on a warm worktree that pulls zero bytes" \
  "ok  bakegate AC7 setup: the run itself was warm" \
  "ok  bakegate AC7: the journal names it a warm worktree needing a fresh one" \
  "ok  bakegate AC7: stderr reads the same explanation"
