#!/usr/bin/env bash
# pullback_ac9_pybuilder_pull.sh — PRD-build-burst-pull-back-restore AC9.
#
# Given a Python worktree, When `pull` runs, Then `.pybuilder/` is fetched
# back and `target/` is not.
#
# Matches scripts/burst-lane-selftest.sh's uv-routed python run/pull block
# (~line 476).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullback-ac-common.sh"
pullback_run_suite

fail=0
for line in \
  "ok  python run does NOT pull .pybuilder/ back itself (burstpull req 1)" \
  "ok  python run journaled dirty=1 kind=pybuilder (burstpull req 1)" \
  "ok  explicit pull fetches .pybuilder/ back, not target/ (burstpull req 3)" \
; do
  if grep -qF "$line" <<<"$PULLBACK_OUT"; then
    echo "$line"
  else
    echo "FAIL pullback AC9: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
