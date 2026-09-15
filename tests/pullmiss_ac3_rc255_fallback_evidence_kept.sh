#!/usr/bin/env bash
# pullmiss_ac3_rc255_fallback_evidence_kept.sh — PRD-build-burst-pull-
# remote-target-missing AC3.
#
# Given the fake rsync exits 255 with ssh: connect to host ... Connection
# refused, When pull runs, Then the fallback line contains
# rc=255 err="ssh: connect to host and attempts=1 next_retry_s=30, and
# $STATE_DIR/logs/pull-fail.*.log holds the full stderr.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullmiss-ac-common.sh"
pullmiss_run_suite

fail=0
for line in \
  "ok  AC3: rc255 pull exits non-zero" \
  "ok  AC3: fallback line carries cause=ssh-failed rc=255 and the err text" \
  "ok  AC3: fallback line carries attempts=1 next_retry_s=30" \
  "ok  AC3: pull-fail log exists and is kept" \
  "ok  AC3: pull-fail log holds the FULL rsync stderr" \
; do
  if grep -qF "$line" <<<"$PULLMISS_OUT"; then
    echo "$line"
  else
    echo "FAIL pullmiss AC3: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
