#!/usr/bin/env bash
# pullmiss_ac2_rc23_never_rsync_failed.sh — PRD-build-burst-pull-remote-
# target-missing AC2.
#
# Given the fake rsync exits 23 with change_dir ... failed: No such file or
# directory, When pull runs, Then the outcome is cold with
# cause=remote-target-missing (never rsync-failed).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullmiss-ac-common.sh"
pullmiss_run_suite

fail=0
for line in \
  "ok  AC2: rc23 target-missing pull exits 0 (cold, not a failure)" \
  "ok  AC2: stdout reports cold" \
  "ok  AC2: journal cause is remote-target-missing" \
  "ok  AC2: never journaled as cause=rsync-failed" \
; do
  if grep -qF "$line" <<<"$PULLMISS_OUT"; then
    echo "$line"
  else
    echo "FAIL pullmiss AC2: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
