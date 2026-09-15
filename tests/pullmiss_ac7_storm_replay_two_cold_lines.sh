#!/usr/bin/env bash
# pullmiss_ac7_storm_replay_two_cold_lines.sh — PRD-build-burst-pull-
# remote-target-missing AC7.
#
# Given the 2026-09-15 burst-lane.log 12:00-13:10Z window replayed through
# the fixture (two worktrees, remote target absent), When the selftest
# runs, Then exactly 2 `pull cold` lines are produced where the real log
# had 246 fallbacks.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullmiss-ac-common.sh"
pullmiss_run_suite

fail=0
for line in \
  "ok  AC7: worktree A -> exactly one cold line despite 123 rapid reads" \
  "ok  AC7: worktree B -> exactly one cold line despite 123 rapid reads" \
  "ok  AC7: zero fallback lines anywhere (never mistaken for rsync-failed)" \
; do
  if grep -qF "$line" <<<"$PULLMISS_OUT"; then
    echo "$line"
  else
    echo "FAIL pullmiss AC7: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
