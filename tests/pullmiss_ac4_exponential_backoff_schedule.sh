#!/usr/bin/env bash
# pullmiss_ac4_exponential_backoff_schedule.sh — PRD-build-burst-pull-
# remote-target-missing AC4.
#
# Given that marker, When local-read pulls are attempted 20 times over a
# simulated 10 minutes (injected clock), Then at most 5 ssh/rsync attempts
# occur (30, 60, 120, 240, 480 s) and the remaining calls journal at most
# one `pull backoff` line per window.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullmiss-ac-common.sh"
pullmiss_run_suite

fail=0
for line in \
  "ok  AC4: at most 5 real rsync attempts over 20 local-read calls / 600s" \
  "ok  AC4: at most one backoff line per window (<=4 windows opened)" \
  "ok  AC4: backoff delays are exactly 30 60 120 240 480 in order" \
; do
  if grep -qF "$line" <<<"$PULLMISS_OUT"; then
    echo "$line"
  else
    echo "FAIL pullmiss AC4: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
