#!/usr/bin/env bash
# pullmiss_ac5_stuck_after_8_attempts_resets_on_new_run.sh —
# PRD-build-burst-pull-remote-target-missing AC5.
#
# Given 8 consecutive failures, When the 9th local-read occurs, Then no ssh
# call is made, one `pull stuck` line exists, and status --json shows the
# marker with stuck:true; Given a new routed run rewrites the marker, Then
# attempts is 0 and pulls resume.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullmiss-ac-common.sh"
pullmiss_run_suite

fail=0
for line in \
  "ok  AC5: exactly one 'pull stuck' line after 8 consecutive failures" \
  "ok  AC5: status --json shows stuck:true" \
  "ok  AC5: 9th local-read makes no ssh call (journals nothing new)" \
  "ok  AC5: still exactly one stuck line (not re-journaled)" \
  "ok  AC5: a new routed run resets attempts to 0" \
  "ok  AC5: a new routed run resets stuck to false" \
; do
  if grep -qF "$line" <<<"$PULLMISS_OUT"; then
    echo "$line"
  else
    echo "FAIL pullmiss AC5: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
