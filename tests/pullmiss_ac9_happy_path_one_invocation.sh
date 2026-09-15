#!/usr/bin/env bash
# pullmiss_ac9_happy_path_one_invocation.sh — PRD-build-burst-pull-remote-
# target-missing AC9.
#
# Given a present remote target/ (happy path), When pull runs, Then
# exactly one ssh/rsync invocation occurs (no extra probe) and the
# `pull ok` line is unchanged from today's shape.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullmiss-ac-common.sh"
pullmiss_run_suite

fail=0
for line in \
  "ok  AC9: happy-path pull makes exactly one rsync invocation (no extra probe)" \
  "ok  AC9: pull succeeds and reports pulled" \
  "ok  AC9: 'pull ok' line shape is unchanged" \
; do
  if grep -qF "$line" <<<"$PULLMISS_OUT"; then
    echo "$line"
  else
    echo "FAIL pullmiss AC9: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
