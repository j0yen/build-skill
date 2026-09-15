#!/usr/bin/env bash
# pullmiss_ac6_explicit_pull_ignores_backoff.sh — PRD-build-burst-pull-
# remote-target-missing AC6.
#
# Given a stuck marker, When `burst-lane.sh pull <worktree>` (explicit)
# runs, Then one rsync attempt is made regardless of backoff.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullmiss-ac-common.sh"
pullmiss_run_suite

fail=0
for line in \
  "ok  AC6 setup: marker is stuck" \
  "ok  AC6: explicit pull on a stuck marker still attempts once (exits non-zero)" \
  "ok  AC6: exactly one more rsync attempt was made (ignoring backoff/stuck)" \
; do
  if grep -qF "$line" <<<"$PULLMISS_OUT"; then
    echo "$line"
  else
    echo "FAIL pullmiss AC6: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
