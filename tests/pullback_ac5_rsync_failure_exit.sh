#!/usr/bin/env bash
# pullback_ac5_rsync_failure_exit.sh — PRD-build-burst-pull-back-restore
# AC5.
#
# Given a transfer whose underlying rsync fails, When `pull` runs, Then
# `pull` exits non-zero and journals the failure cause.
#
# Implemented: scripts/burst-lane-selftest.sh's "pullback AC5" fixture
# marks a worktree dirty via a real `run`, then forces FAKE_RSYNC_FAIL=1
# on an explicit `pull` — do_marker_pull's own real-failure branch (rsync
# ran, box/dir exist, transfer itself failed -> marker left dirty, rc1,
# journaled cause=rsync-failed) now has a fixture proving it, distinct
# from every deferred/cold outcome (pinned exit 0) elsewhere in the suite.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullback-ac-common.sh"
pullback_run_suite

fail=0

for line in \
  "ok  pullback AC5 setup: run left the worktree dirty" \
  "ok  pullback AC5: pull exits non-zero on a real rsync-down failure" \
  "ok  pullback AC5: stdout reports the fallback, never claims 'pulled'" \
  "ok  pullback AC5: the marker is left dirty for a later retry" \
  "ok  pullback AC5: journal names the rsync failure cause" \
; do
  if grep -qF "$line" <<<"$PULLBACK_OUT"; then
    echo "$line"
  else
    echo "FAIL pullback AC5: missing/failed: $line" >&2
    fail=1
  fi
done

exit $fail
