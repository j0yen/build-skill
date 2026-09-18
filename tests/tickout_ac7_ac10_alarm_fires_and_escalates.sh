#!/usr/bin/env bash
# tickout_ac7_ac10_alarm_fires_and_escalates.sh —
# PRD-buildloop-tick-outcome-liveness AC7 + AC10.
#
# AC7: given three consecutive failures with cause auth-expired, the
# third tick makes exactly one loop-tick-failed call with --value 3 and
# the journal has ALARM loop-tick-failed ... cause=auth-expired streak=3
# last_ok=<ts>; a fourth failure the same day makes no second call.
# AC10: given a streak reaching 6, a --comment re-delivery is made with
# --value 6; at 7-11 none (not exercised here, covered by construction:
# the delivery condition is `streak == base*2`, an equality check, not a
# range).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
mkdir -p "$BUILD_STATE_DIR"

CALL_LOG="$TMP/alert-calls.log"
: > "$CALL_LOG"
FAKE_ALERT="$TMP/fake-alert-deliver.sh"
cat > "$FAKE_ALERT" <<EOF
#!/usr/bin/env bash
echo "CALL: \$*" >> "$CALL_LOG"
exit 0
EOF
chmod +x "$FAKE_ALERT"
export TICK_RUN_ALERT_DELIVER="$FAKE_ALERT"

FAKE_CLAUDE="$TMP/fake-claude.sh"
cat > "$FAKE_CLAUDE" <<'EOF'
#!/usr/bin/env bash
echo "Failed to authenticate: OAuth session expired and could not be refreshed" >&2
exit 1
EOF
chmod +x "$FAKE_CLAUDE"

fail=0

for i in 1 2 3; do
  CLAUDE_BIN="$FAKE_CLAUDE" "$SCRIPT" >/dev/null 2>&1
done

calls_after_3="$(grep -c '^CALL:' "$CALL_LOG")"
if [ "$calls_after_3" -eq 1 ] && grep -q 'loop-tick-failed build-loop' "$CALL_LOG" && grep -q -- '--value 3' "$CALL_LOG"; then
  echo "ok  AC7: exactly one call at streak=3, --value 3"
else
  echo "FAIL: expected exactly one --value 3 call, got:"
  cat "$CALL_LOG"
  fail=1
fi

if grep -q -- '--comment' "$CALL_LOG"; then
  echo "FAIL: --comment present at streak=3 (should only appear at 6/12)"
  fail=1
else
  echo "ok  AC7: no --comment at streak=3"
fi

if grep -qE 'ALARM  loop-tick-failed  cause=auth-expired streak=3 last_ok=(unknown|[0-9TZ:-]+)$' "$TICK_RUN_JOURNAL"; then
  echo "ok  AC7: journal has ALARM loop-tick-failed cause=auth-expired streak=3"
else
  echo "FAIL: journal missing expected ALARM line:"
  cat "$TICK_RUN_JOURNAL"
  fail=1
fi

# 4th failure the same day: no second call.
CLAUDE_BIN="$FAKE_CLAUDE" "$SCRIPT" >/dev/null 2>&1
calls_after_4="$(grep -c '^CALL:' "$CALL_LOG")"
if [ "$calls_after_4" -eq 1 ]; then
  echo "ok  AC7: 4th failure makes no second call"
else
  echo "FAIL: expected still 1 call after streak=4, got $calls_after_4:"
  cat "$CALL_LOG"
  fail=1
fi

# 5th (streak=5): still no call. 6th (streak=6): --comment re-delivery.
CLAUDE_BIN="$FAKE_CLAUDE" "$SCRIPT" >/dev/null 2>&1   # streak=5
calls_after_5="$(grep -c '^CALL:' "$CALL_LOG")"
CLAUDE_BIN="$FAKE_CLAUDE" "$SCRIPT" >/dev/null 2>&1   # streak=6
calls_after_6="$(grep -c '^CALL:' "$CALL_LOG")"

if [ "$calls_after_5" -eq 1 ]; then
  echo "ok  AC10: streak=5 makes no call"
else
  echo "FAIL: expected 1 call after streak=5, got $calls_after_5"
  fail=1
fi

if [ "$calls_after_6" -eq 2 ] && grep -q -- '--value 6' "$CALL_LOG" && grep -A0 -- '--value 6' "$CALL_LOG" | grep -q -- '--comment'; then
  echo "ok  AC10: streak=6 delivers --value 6 --comment (2nd call total)"
else
  echo "FAIL: expected a 2nd call at streak=6 with --value 6 --comment:"
  cat "$CALL_LOG"
  fail=1
fi

exit "$fail"
