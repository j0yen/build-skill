#!/usr/bin/env bash
# tickout_ac6_skip_tick_lock_held_never_ok.sh —
# PRD-buildloop-tick-outcome-liveness AC6 (skip-path half): a tick-lock-
# held skip is outcome=skipped cause=tick-lock-held, never outcome=ok —
# R3/AC6 requires a missing/non-ok record to never read as a live "ok".
# This exercises the OTHER write site (the early flock-held exit,
# tick-run.sh line ~357), which none of the other tickout_* fixtures
# reach (they all substitute a fake coordinator and never contend the
# lock itself).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"
JQ="${JQ:-jq}"

TMP="$(mktemp -d)"
trap 'kill "${BGPID:-0}" 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
mkdir -p "$BUILD_STATE_DIR"

"$SCRIPT" -- sleep 30 &
BGPID=$!
sleep 1

"$SCRIPT" -- true >/dev/null 2>&1
rc=$?

fail=0
OUT="$BUILD_STATE_DIR/tick-outcome.json"
[ -f "$OUT" ] || { echo "FAIL: $OUT not written on tick-lock-held skip"; exit 1; }
[ "$rc" -eq 75 ] && echo "ok  AC6: second launch exit=75" || { echo "FAIL: exit=$rc want 75"; fail=1; }

outcome="$("$JQ" -r '.outcome' "$OUT")"
cause="$("$JQ" -r '.cause' "$OUT")"

[ "$outcome" = skipped ] && echo "ok  AC6: outcome=skipped (never ok)" || { echo "FAIL: outcome=$outcome want skipped"; fail=1; }
[ "$cause" = tick-lock-held ] && echo "ok  AC6: cause=tick-lock-held" || { echo "FAIL: cause=$cause want tick-lock-held"; fail=1; }

exit "$fail"
