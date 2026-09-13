#!/usr/bin/env bash
# pullback_ac4_remote_path_missing_cold.sh — PRD-build-burst-pull-back-
# restore AC4.
#
# Given a remote path that does not exist, When `pull` runs, Then it
# journals `pull cold cause=remote-path-missing`, clears the stale marker,
# and prints `cold`, not `pulled`.
#
# Matches scripts/burst-lane-selftest.sh's "burstvol AC10" block (~line
# 3288): a dirty marker naming a remote_path under a moved $REMOTE_ROOT is
# treated as cold, cleared, and never retried as rsync-failed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullback-ac-common.sh"
pullback_run_suite

fail=0
for line in \
  "ok  burstvol AC10: pull against a marker under a moved root exits 0 (cold, not an error)" \
  "ok  burstvol AC10: journal records pull cold cause=remote-path-missing" \
  "ok  burstvol AC10: never journaled as rsync-failed for this worktree" \
  "ok  burstvol AC10: the stale marker was cleared" \
  "ok  burstpull AC2: cold pull's stdout never claims 'pulled'" \
; do
  if grep -qF "$line" <<<"$PULLBACK_OUT"; then
    echo "$line"
  else
    echo "FAIL pullback AC4: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
