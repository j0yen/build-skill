#!/usr/bin/env bash
# provefx_ac14_offroot_target_dir_assert.sh —
# PRD-build-burst-prove-forensics AC14.
#
# Given a fixture worktree whose .cargo/config.toml sets an absolute
# off-root target-dir, When prove runs, Then the pull writes under that
# override, assert inspects that same path (journal line names
# local_target=<override>), and the verdict is routed=true.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC14: prove routes true against an off-root target-dir override" \
  "ok  provefx AC14: proof.json routed=true" \
  'ok  provefx AC14: the pull actually landed the artifact under the override, not $worktree/target' \
  "ok  provefx AC14: the done journal line names local_target as the override path"
