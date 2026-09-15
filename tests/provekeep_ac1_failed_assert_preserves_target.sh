#!/usr/bin/env bash
# provekeep_ac1_failed_assert_preserves_target.sh — PRD-build-burst-prove-
# evidence-preservation AC1 (P0).
#
# Given a fixture prove whose assert fails (the existing provefx
# no-fresh-artifact case), When prove exits, Then
# state/burst-lane/evidence/<ts>-<server_id>/ contains target/ with the
# pulled files, proof.json, the step logs, and expression.sh, and the
# disposable worktree is gone.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provekeep AC1: prove exits 1 on the no-fresh-artifact fixture" \
  "ok  provekeep AC1: exactly one evidence dir was created" \
  "ok  provekeep AC1: evidence dir holds target/, proof.json, expression.sh, and a step log" \
  "ok  provekeep AC1: the disposable worktree is gone"
