#!/usr/bin/env bash
# pathws_ac2_external_sibling_still_mirrored.sh — PRD-build-burst-path-deps-
# workspaces AC2.
#
# Given the same workspace plus an external sibling ../c, When `run`
# executes, Then c is mirrored under deps/ and recorded in remote-dirs.json
# with owner a's worktree.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  pathws AC2: run against a workspace member with an external sibling exits 0" \
  "ok  pathws AC2: cargo metadata resolved both the in-workspace and external siblings" \
  "ok  pathws AC2: the external sibling WAS mirrored under deps/" \
  "ok  pathws AC2: remote-dirs.json records the mirror with owner = a's own worktree"
