#!/usr/bin/env bash
# pullback_ac1_fixture_floor_control.sh — PRD-build-burst-pull-back-restore
# AC1.
#
# Given the selftest running on a filesystem with less free space than the
# default floor, When it starts, Then it sets the fixture floor explicitly
# and journals the worktree filesystem and free space, and its
# non-deferral pull fixtures journal `pull ok`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullback-ac-common.sh"
pullback_run_suite

fail=0

# Second half first, since it's the half that's real: with the floor
# controlled (this wrapper's own BURST_LOCAL_DISK_FLOOR_GB=2 override — see
# the fixture header), a non-deferral pull fixture actually transfers and
# journals ok.
for line in \
  "ok  explicit pull succeeds (burstpull req 3)" \
  "ok  explicit pull fetched target/ back (burstpull req 3)" \
  "ok  first explicit pull journaled a byte count (req 10)" \
; do
  if grep -qF "$line" <<<"$PULLBACK_OUT"; then
    echo "$line"
  else
    echo "FAIL pullback AC1: missing/failed under the controlled floor: $line" >&2
    fail=1
  fi
done

# First half: does the SUITE ITSELF (not this wrapper's external env
# override) set the fixture floor and journal the worktree filesystem +
# free space at start? Nothing in burst-lane-selftest.sh does this today —
# fresh_env (scripts/burst-lane-selftest.sh ~line 241) never sets
# BURST_LOCAL_DISK_FLOOR_GB, and no line anywhere in the suite journals a
# worktree filesystem or free-space reading at startup. This is a real,
# unimplemented half of AC1, not a tmpfs artifact this wrapper can paper
# over — reported here as a gap rather than a tautological pass.
if grep -qiE 'worktree filesystem|worktree fs=|fixture floor|floor set to' <<<"$PULLBACK_OUT"; then
  echo "ok  pullback AC1: the suite itself sets the fixture floor and journals worktree filesystem/free space"
else
  echo "FAIL pullback AC1: GAP — the suite itself never sets BURST_LOCAL_DISK_FLOOR_GB nor journals its worktree filesystem/free space at start; this wrapper supplies BURST_LOCAL_DISK_FLOOR_GB=$PULLBACK_FLOOR_GB externally (an override burst-lane.sh already honors, per its own comment at line ~493) only so the downstream pull-back ACs are exercisable at all. The suite-side half of AC1 (self-directed floor control + startup journaling) is not implemented." >&2
  fail=1
fi

exit $fail
