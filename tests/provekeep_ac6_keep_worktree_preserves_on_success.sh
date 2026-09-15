#!/usr/bin/env bash
# provekeep_ac6_keep_worktree_preserves_on_success.sh — PRD-build-burst-
# prove-evidence-preservation AC6 (P1).
#
# Given `prove --keep-worktree` on a successful fixture prove, When it
# exits, Then an evidence set exists and the journal has
# `prove  evidence-kept  (reason=operator)`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provekeep AC6 setup: the fixture prove succeeded (routed=true)" \
  "ok  provekeep AC6: --keep-worktree preserves an evidence set on a successful prove" \
  "ok  provekeep AC6: journal has prove evidence-kept (reason=operator)" \
  "ok  provekeep AC6: the operator-supplied worktree itself is untouched (copied, not moved)"
