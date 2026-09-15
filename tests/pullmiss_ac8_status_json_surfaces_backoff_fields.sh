#!/usr/bin/env bash
# pullmiss_ac8_status_json_surfaces_backoff_fields.sh —
# PRD-build-burst-pull-remote-target-missing AC8.
#
# Given a marker with attempts 3 and a future next_retry_epoch, When
# status --json runs, Then the dirty[] entry shows attempts:3,
# next_retry_epoch, stuck:false, and last_err.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullmiss-ac-common.sh"
pullmiss_run_suite

fail=0
for line in \
  "ok  AC8: status --json attempts is 3" \
  "ok  AC8: status --json stuck is false" \
  "ok  AC8: status --json next_retry_epoch is present and numeric" \
  "ok  AC8: status --json last_err names the fixture failure" \
; do
  if grep -qF "$line" <<<"$PULLMISS_OUT"; then
    echo "$line"
  else
    echo "FAIL pullmiss AC8: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
