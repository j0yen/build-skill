#!/usr/bin/env bash
# pullback_ac6_incremental_byte_delta.sh — PRD-build-burst-pull-back-restore
# AC6.
#
# Given two successive pulls of unchanged content, When both complete,
# Then each journals a byte count and the second's is smaller than the
# first's.
#
# Matches scripts/burst-lane-selftest.sh's AC1/AC11 byte-count block
# (~lines 398-439): bytes1 from the first explicit pull, a re-dirtying run,
# then bytes2 from a second explicit pull of the same worktree — asserted
# smaller (incremental rsync delta reuse).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullback-ac-common.sh"
pullback_run_suite

fail=0
for line in \
  "ok  first explicit pull journaled a byte count (req 10)" \
  "ok  second explicit pull journaled a byte count (req 10)" \
  "ok  second explicit pull's bytes are fewer than the first's (AC11, incremental delta reuse)" \
; do
  if grep -qF "$line" <<<"$PULLBACK_OUT"; then
    echo "$line"
  else
    echo "FAIL pullback AC6: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
