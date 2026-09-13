#!/usr/bin/env bash
# pullback_ac7_local_read_attribution.sh — PRD-build-burst-pull-back-restore
# AC7.
#
# Given a local read that triggers a pull, When it completes, Then exactly
# one attribution row exists with `trigger=local-read` and the reading
# slug, and the pull happened before the local cargo ran.
#
# Matches scripts/burst-lane-selftest.sh's "burstpull AC2" local-read block
# (~line 570): the cargo shim's local fallback pulls the dirty worktree
# back before running local cargo, clears the marker, and lands exactly
# one trigger=local-read attribution row.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullback-ac-common.sh"
pullback_run_suite

fail=0
for line in \
  "ok  burstpull AC2: shim ran local cargo (after the pull)" \
  "ok  burstpull AC2: one pull happened before the local cargo ran" \
  "ok  burstpull AC2: marker cleared after the local-read pull" \
  "ok  burstpull AC2: exactly one pull attribution row, trigger=local-read, reading slug (req 2)" \
; do
  if grep -qF "$line" <<<"$PULLBACK_OUT"; then
    echo "$line"
  else
    echo "FAIL pullback AC7: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
