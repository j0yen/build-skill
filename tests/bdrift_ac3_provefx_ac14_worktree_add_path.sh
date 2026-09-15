#!/usr/bin/env bash
# bdrift_ac3_provefx_ac14_worktree_add_path.sh —
# PRD-build-burst-selftest-drift-and-bake-gate AC3.
#
# Given provefx AC14's repo fixture with .cargo/config.toml excluded, When
# prove runs without --worktree, Then the fixture asserts the disposable
# worktree has no .cargo/config.toml and proof.json's local_target ends in
# /target under that worktree (requirement 3, case 1).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC14: git worktree add from this fixture's repo produces a worktree with no .cargo/config.toml" \
  "ok  provefx AC14: prove with no --worktree does its own git worktree add --detach and still routes true" \
  "ok  provefx AC14: prove's own disposable worktree is gone after prove finishes" \
  "ok  provefx AC14: the done journal line names local_target as <worktree>/target, not the repo's off-root override"
