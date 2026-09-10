#!/usr/bin/env bash
# costattr_ac1_worktree_slug_derivation.sh — PRD-build-cost-attribution AC1.
#
# Given a routed run for worktree mcphost-mcphost-schedules, when it
# completes, then an attribution row exists with slug=mcphost-schedules,
# wall seconds >0, and the run's bytes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC1: attribution row derives slug=mcphost-schedules from the worktree basename" \
  "ok  AC1: attribution row has wall_seconds > 0" \
  "ok  AC1: attribution row carries the run's bytes"
