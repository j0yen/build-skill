#!/usr/bin/env bash
# bdrift_ac4_provefx_ac14_offroot_worktree_override.sh —
# PRD-build-burst-selftest-drift-and-bake-gate AC4.
#
# Given the same fixture with --worktree pointing at a checkout containing
# the file, When prove runs, Then proof.json's local_target is the
# off-root directory named in the file (requirement 3, case 2 — this is
# the pre-existing provefx AC14 case, unchanged by this PRD).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC14: prove routes true against an off-root target-dir override" \
  "ok  provefx AC14: proof.json routed=true" \
  'ok  provefx AC14: the pull actually landed the artifact under the override, not $worktree/target' \
  "ok  provefx AC14: the done journal line names local_target as the override path"
