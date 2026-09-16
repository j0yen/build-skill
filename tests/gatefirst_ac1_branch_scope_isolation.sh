#!/usr/bin/env bash
# gatefirst_ac1_branch_scope_isolation.sh — PRD-build-gate-before-land AC1.
#
# Given a worktree with an off-root target and a fixture crate, When
# `extend-gate.sh <worktree> --head <sha> --scope branch` runs, Then
# receipts and last-verdict.json exist under the worktree's resolved
# target dir, no autobuilder-integrate.lock was acquired, and the journal
# line carries scope=branch slug=... base=<main sha>.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatefirst-ac-common.sh"
run_scope_and_expect_labels \
  "ok  AC1a: worktree's target/ is a symlink to the off-root target dir" \
  "ok  AC1a: receipts exist under the worktree's resolved (off-root) target dir" \
  "ok  AC1a: last-verdict.json exists under the worktree's resolved (off-root) target dir" \
  "ok  AC1b: per-branch lock file was created" \
  "ok  AC1b: no autobuilder-integrate.lock was ever acquired" \
  "ok  AC1c: a gate journal line was written" \
  "ok  AC1c: journal line carries scope=branch slug=" \
  "ok  AC1c: journal line's base= names the ADVANCED main HEAD" \
  "ok  AC1c: journal line's base= is NOT the worktree's own HEAD"
