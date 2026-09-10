#!/usr/bin/env bash
# burstpull_ac3_status_age_and_explicit_pull.sh — PRD-build-burst-pull-on-demand AC3.
#
# Given a dirty worktree, when `burst-lane.sh status` runs, then the
# worktree is listed dirty with age; when `burst-lane.sh pull <worktree>`
# runs, then the pull executes and the marker clears.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  run leaves the worktree listed dirty by status (burstpull req 3)" \
  "ok  status lists the dirty worktree with age (burstpull req 3 / AC3)" \
  "ok  explicit pull succeeds (burstpull req 3)" \
  "ok  explicit pull fetched target/ back (burstpull req 3)" \
  "ok  explicit pull cleared the dirty marker (burstpull req 3)"
