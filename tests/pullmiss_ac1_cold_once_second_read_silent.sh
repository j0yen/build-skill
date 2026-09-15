#!/usr/bin/env bash
# pullmiss_ac1_cold_once_second_read_silent.sh — PRD-build-burst-pull-
# remote-target-missing AC1.
#
# Given a dirty marker whose remote_path exists on the fake box but has no
# target/, When do_marker_pull runs with trigger=local-read, Then the
# marker is cleared, one `pull cold ... cause=remote-target-missing` line
# is journaled, and a second read journals nothing and makes no ssh call.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullmiss-ac-common.sh"
pullmiss_run_suite

fail=0
for line in \
  "ok  AC1 setup: run left the worktree dirty" \
  "ok  AC1: ensure-fresh (local-read) exits 0" \
  "ok  AC1: marker is cleared" \
  "ok  AC1: journal names cause=remote-target-missing" \
  "ok  AC1: second read reports clean (nothing left to pull)" \
  "ok  AC1: second read journals nothing (no ssh call — marker already gone)" \
; do
  if grep -qF "$line" <<<"$PULLMISS_OUT"; then
    echo "$line"
  else
    echo "FAIL pullmiss AC1: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
