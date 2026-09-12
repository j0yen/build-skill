#!/usr/bin/env bash
# pathws_ac6_selftest_names_pathws_cases.sh — PRD-build-burst-path-deps-
# workspaces AC6 (P1).
#
# Given the selftest fixture set, When `burst-lane-selftest.sh` runs, Then
# it exits 0 and names the `pathws` cases.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  pathws AC1: run against a workspace member exits 0" \
  "ok  pathws AC2: the external sibling WAS mirrored under deps/" \
  "ok  pathws AC3: reap removes the mirror once its owner worktree is gone" \
  "ok  pathws AC4: the 4th attempt at an unchanged HEAD is refused (exit 3)" \
  "ok  pathws AC6: every pathws case above ran green"
