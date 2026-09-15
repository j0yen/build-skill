#!/usr/bin/env bash
# provekeep_ac5_successful_prove_no_evidence.sh — PRD-build-burst-prove-
# evidence-preservation AC5 (P0, non-goal check).
#
# Given a successful fixture prove without --keep-worktree, When it exits,
# Then no evidence directory is created.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provekeep AC5 setup: the fixture prove succeeded (routed=true)" \
  "ok  provekeep AC5: no evidence directory is created for a successful prove without --keep-worktree"
