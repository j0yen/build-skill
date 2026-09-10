#!/usr/bin/env bash
# burstpull_ac5_pull_refused_while_run_holds_lock.sh — PRD-build-burst-pull-on-demand AC5.
#
# Given a pull requested while a remote run holds the worktree's slot, when
# it starts, then it is refused with a named error and no rsync runs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstpull AC5: explicit pull is refused while the worktree lock is held" \
  "ok  burstpull AC5: refusal names the cause" \
  "ok  burstpull AC5: refusal journaled"
