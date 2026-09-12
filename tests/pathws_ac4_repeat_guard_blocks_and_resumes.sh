#!/usr/bin/env bash
# pathws_ac4_repeat_guard_blocks_and_resumes.sh — PRD-build-burst-path-deps-
# workspaces AC4.
#
# Given three consecutive build-failed runs with the same cause on one
# worktree within 15 minutes, When a fourth is attempted, Then the shim
# exits 3 without running cargo and journals build-failed repeated
# (n=3 cause=...); given a new HEAD, Then attempts resume.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  pathws AC4: the 4th attempt at an unchanged HEAD is refused (exit 3)" \
  "ok  pathws AC4: the refusal names it as repeated" \
  "ok  pathws AC4: journal names n=3 and the worktree" \
  "ok  pathws AC4: the 4th attempt made no ssh call at all (no cargo ever ran)" \
  "ok  pathws AC4: a new HEAD lets attempts resume (not the repeated refusal)" \
  "ok  pathws AC4: the resumed attempt actually reached the box"
