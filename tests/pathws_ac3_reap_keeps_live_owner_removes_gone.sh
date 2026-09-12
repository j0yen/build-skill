#!/usr/bin/env bash
# pathws_ac3_reap_keeps_live_owner_removes_gone.sh — PRD-build-burst-path-
# deps-workspaces AC3.
#
# Given remote-dirs.json naming deps/ with a live owner, When `reap` runs,
# Then deps/ is kept; given the owner worktree removed, Then it is reaped
# with reason=owner-gone.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  pathws AC3: setup — the external sibling mirror exists before reap" \
  "ok  pathws AC3: reap keeps the mirror while its owner worktree still exists" \
  "ok  pathws AC3: reap journaled no removal for the still-owned mirror" \
  "ok  pathws AC3: reap removes the mirror once its owner worktree is gone" \
  "ok  pathws AC3: reap journals reason=owner-gone (never the bare deps/ container)"
