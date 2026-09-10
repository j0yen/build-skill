#!/usr/bin/env bash
# burstpull_ac4_teardown_sweep_survives_cold_and_busy.sh — PRD-build-burst-pull-on-demand AC4.
#
# Given three dirty worktrees at teardown with one whose remote dir is
# missing (and, per requirement 4, one held busy by a live run), when
# `down` runs, then the pullable worktrees are pulled, the cold one is
# journaled cold and cleared, a busy one is skipped without aborting the
# sweep, the sweep exits successfully, and the box is deleted only after
# the sweep.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstpull AC4 setup: mcphost-sw-one is dirty before teardown" \
  "ok  burstpull AC4 setup: mcphost-sw-two is dirty before teardown" \
  "ok  burstpull AC4 setup: mcphost-sw-cold is dirty before teardown" \
  "ok  burstpull AC4 setup: mcphost-sw-busy is dirty before teardown" \
  "ok  burstpull AC4: teardown still deletes cleanly despite one cold + one busy worktree" \
  "ok  burstpull AC4: the two pullable worktrees got their target/ back" \
  "ok  burstpull AC4: the cold worktree's target/ was never fetched" \
  "ok  burstpull AC4: the busy worktree's target/ was never fetched either (sweep skipped it, did not wait)" \
  "ok  burstpull AC4: the pulled/cold markers are cleared after the sweep" \
  "ok  burstpull AC4: the busy worktree's marker is LEFT dirty for a later retry (sweep does not abort on it)" \
  "ok  burstpull AC4: the cold worktree was journaled cold, not silently dropped" \
  "ok  burstpull AC4: the busy worktree's sweep failure is journaled, and the sweep continued past it"
