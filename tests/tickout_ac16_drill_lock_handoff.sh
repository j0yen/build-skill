#!/usr/bin/env bash
# tickout_ac16_drill_lock_handoff.sh —
# PRD-buildloop-tick-outcome-liveness AC16 (runnability half).
#
# AC16's drill is the ONLY thing that proves the real claude binary's
# real auth-failure text still matches lib/tick-cause.sh. For ten
# dispatches it could not run at all: every inner tick-run.sh call lost
# its `flock -n` to the tick that was asking for the drill, recorded
# `skipped cause=tick-lock-held`, and the drill failed its own
# cause!=auth-expired assertion. On a host whose claude-build.timer fires
# every five minutes there is no reliable idle window to hand an operator
# either, so "run it when the loop is quiet" was not a real instruction.
#
# The fix has two halves, and this fixture pins both:
#   1. tick-run.sh honors TICK_RUN_ASSUME_LOCK=1 — run the child without
#      re-taking a lock the CALLER already holds, and without touching
#      the holder file the caller owns.
#   2. loop-arm-drill.sh takes tick.lock itself, waiting for an in-flight
#      tick, and HOLDS it across all three drill ticks — so no real tick
#      can land in between and reset streak_failed to 0 with its own `ok`
#      record, which would make streak=3 (and therefore AC16's own alarm
#      evidence) unreachable.
#
# Every part below is hermetic: fake claude, fake alert-deliver, temp
# state dir, temp journal root, LOOP_ARM_BUILD_HOST forced to this host.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TICK_RUN_SH="$HERE/../scripts/tick-run.sh"
DRILL="$HERE/../scripts/loop-arm-drill.sh"
JQ="${JQ:-jq}"

TMP="$(mktemp -d)"
# NOTE: never `kill "${BGPID:-0}"` here — an empty BGPID collapses to 0,
# and `kill 0` signals this script's whole process group (including the
# harness that invoked it). Guard on non-empty instead.
cleanup() {
  [ -n "${BGPID:-}" ] && kill "$BGPID" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

FAKE_CLAUDE="$TMP/fake-claude.sh"
cat > "$FAKE_CLAUDE" <<'EOF'
#!/usr/bin/env bash
echo "Failed to authenticate: OAuth session expired and could not be refreshed" >&2
exit 1
EOF
chmod +x "$FAKE_CLAUDE"

CALL_LOG="$TMP/alert-calls.log"
: > "$CALL_LOG"
FAKE_ALERT="$TMP/fake-alert-deliver.sh"
cat > "$FAKE_ALERT" <<EOF
#!/usr/bin/env bash
echo "CALL: \$*" >> "$CALL_LOG"
exit 0
EOF
chmod +x "$FAKE_ALERT"

fail=0

# ---------------------------------------------------------------- part 1
# TICK_RUN_ASSUME_LOCK=1 runs the child even while the lock is genuinely
# held by someone else, and leaves that holder's holder-file untouched.
S1="$TMP/state1"; mkdir -p "$S1"
export BUILD_JOURNAL_ROOT="$TMP/journal1"; mkdir -p "$BUILD_JOURNAL_ROOT"
BUILD_STATE_DIR="$S1" "$TICK_RUN_SH" -- sleep 20 &
BGPID=$!
sleep 1
holder_before="$(cat "$S1/tick.lock.holder" 2>/dev/null)"

# Control: without the flag, a second launch skips (the shipped
# behaviour this fixture must not regress).
BUILD_STATE_DIR="$S1" CLAUDE_BIN="$FAKE_CLAUDE" TICK_RUN_ALERT_DELIVER="$FAKE_ALERT" \
  "$TICK_RUN_SH" >/dev/null 2>&1
rc_plain=$?
outcome_plain="$("$JQ" -r '.outcome' "$S1/tick-outcome.json" 2>/dev/null)"
if [ "$rc_plain" -eq 75 ] && [ "$outcome_plain" = skipped ]; then
  echo "ok  AC16: without the flag a contended launch still skips (rc=75, outcome=skipped)"
else
  echo "FAIL: contended launch rc=$rc_plain outcome=$outcome_plain want 75/skipped"; fail=1
fi

BUILD_STATE_DIR="$S1" TICK_RUN_ASSUME_LOCK=1 CLAUDE_BIN="$FAKE_CLAUDE" \
  TICK_RUN_ALERT_DELIVER="$FAKE_ALERT" "$TICK_RUN_SH" >/dev/null 2>&1
rc_assume=$?
outcome_assume="$("$JQ" -r '.outcome' "$S1/tick-outcome.json" 2>/dev/null)"
cause_assume="$("$JQ" -r '.cause' "$S1/tick-outcome.json" 2>/dev/null)"
if [ "$rc_assume" -eq 1 ] && [ "$outcome_assume" = failed ] && [ "$cause_assume" = auth-expired ]; then
  echo "ok  AC16: TICK_RUN_ASSUME_LOCK=1 ran the child under the caller's lock (rc=1 failed/auth-expired)"
else
  echo "FAIL: assume-lock rc=$rc_assume outcome=$outcome_assume cause=$cause_assume want 1/failed/auth-expired"; fail=1
fi

holder_after="$(cat "$S1/tick.lock.holder" 2>/dev/null)"
if [ -n "$holder_before" ] && [ "$holder_before" = "$holder_after" ]; then
  echo "ok  AC16: assume-lock run left the real holder's tick.lock.holder untouched"
else
  echo "FAIL: holder file changed under assume-lock (before='$holder_before' after='$holder_after')"; fail=1
fi

kill "$BGPID" 2>/dev/null; wait 2>/dev/null; BGPID=""

# ---------------------------------------------------------------- part 2
# --no-wait against a held lock: exit 4, nothing mutated.
S2="$TMP/state2"; mkdir -p "$S2"
export BUILD_JOURNAL_ROOT="$TMP/journal2"; mkdir -p "$BUILD_JOURNAL_ROOT"
BUILD_STATE_DIR="$S2" "$TICK_RUN_SH" -- sleep 20 &
BGPID=$!
sleep 1
BUILD_STATE_DIR="$S2" LOOP_ARM_BUILD_HOST="$(hostname -s 2>/dev/null || hostname)" \
  CLAUDE_BIN="$FAKE_CLAUDE" TICK_RUN_ALERT_DELIVER="$FAKE_ALERT" \
  "$DRILL" --no-wait >/dev/null 2>&1
rc_nowait=$?
if [ "$rc_nowait" -eq 4 ]; then
  echo "ok  AC16: --no-wait against an in-flight tick exits 4 (no mutation)"
else
  echo "FAIL: --no-wait rc=$rc_nowait want 4"; fail=1
fi
if [ ! -f "$S2/tick-outcome.json" ]; then
  echo "ok  AC16: --no-wait wrote no outcome record"
else
  echo "FAIL: --no-wait mutated $S2/tick-outcome.json"; fail=1
fi
kill "$BGPID" 2>/dev/null; wait 2>/dev/null; BGPID=""

# ---------------------------------------------------------------- part 3
# The real thing: a tick is in flight, the drill waits it out, then runs
# all three drill ticks under one continuously-held lock and reaches
# streak=3 + the ALARM journal line.
S3="$TMP/state3"; mkdir -p "$S3"
export BUILD_JOURNAL_ROOT="$TMP/journal3"; mkdir -p "$BUILD_JOURNAL_ROOT"
BUILD_STATE_DIR="$S3" "$TICK_RUN_SH" -- sleep 3 &
BGPID=$!
sleep 0.3
start_epoch="$(date -u +%s)"
BUILD_STATE_DIR="$S3" LOOP_ARM_BUILD_HOST="$(hostname -s 2>/dev/null || hostname)" \
  LOOP_ARM_DRILL_LOCK_WAIT=60 LOOP_ARM_DRILL_CHILD_TIMEOUT=20 \
  CLAUDE_BIN="$FAKE_CLAUDE" TICK_RUN_ALERT_DELIVER="$FAKE_ALERT" \
  "$DRILL" >"$TMP/drill3.log" 2>&1
rc_drill=$?
waited=$(( $(date -u +%s) - start_epoch ))
wait 2>/dev/null; BGPID=""

if [ "$rc_drill" -eq 0 ]; then
  echo "ok  AC16: drill completed through a contended lock (rc=0, waited ${waited}s)"
else
  echo "FAIL: drill rc=$rc_drill (waited ${waited}s) -- see below"; sed -n '1,40p' "$TMP/drill3.log"; fail=1
fi
if [ "$waited" -ge 2 ]; then
  echo "ok  AC16: drill actually waited for the in-flight tick (${waited}s >= 2s)"
else
  echo "FAIL: drill did not wait for the in-flight tick (${waited}s)"; fail=1
fi

streak="$("$JQ" -r '.streak_failed' "$S3/tick-outcome.json" 2>/dev/null)"
cause3="$("$JQ" -r '.cause' "$S3/tick-outcome.json" 2>/dev/null)"
if [ "$streak" = 3 ] && [ "$cause3" = auth-expired ]; then
  echo "ok  AC16: three drill ticks under one held lock reached streak_failed=3 cause=auth-expired"
else
  echo "FAIL: streak_failed=$streak cause=$cause3 want 3/auth-expired"; fail=1
fi

today="$(date -u +%F)"
if grep -qE 'ALARM[[:space:]]+loop-tick-failed.*cause=auth-expired.*streak=3' "$BUILD_JOURNAL_ROOT/$today.md" 2>/dev/null; then
  echo "ok  AC16: ALARM loop-tick-failed ... cause=auth-expired streak=3 landed in the journal"
else
  echo "FAIL: no ALARM loop-tick-failed streak=3 line in $BUILD_JOURNAL_ROOT/$today.md"; fail=1
fi
if grep -q 'CALL: loop-tick-failed build-loop .* --value 3' "$CALL_LOG"; then
  echo "ok  AC16: alert-deliver called once with --value 3"
else
  echo "FAIL: no alert-deliver loop-tick-failed --value 3 call recorded"; fail=1
fi
if [ ! -f "$S3/tick.lock.holder" ]; then
  echo "ok  AC16: drill removed its own tick.lock.holder on exit"
else
  echo "FAIL: $S3/tick.lock.holder survived the drill"; fail=1
fi

exit "$fail"
