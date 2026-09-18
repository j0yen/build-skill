#!/usr/bin/env bash
# tickout_ac10_streak_comment_redelivery.sh —
# PRD-buildloop-tick-outcome-liveness AC10.
#
# AC10: Given a streak reaching 6, When that tick finishes, Then a
# --comment re-delivery is made with --value 6; at 7 through 11 none; at
# 12 one more. This is the dedicated test the AC's own number requires
# (the ac7_ac10 fixture only exercises AC7's streak=3 case and asserts
# AC10 "by construction" without running the streak out) -- verified-
# completed.sh's --derive pairing also needs a file literally named
# tickout_ac10_*, since a prefix collision with another PRD's own ac10
# file (tests/landres_ac10_worktree_extend_land_resolves.sh) is exactly
# what an absent tickout_ac10_* file produces.
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

calls_at_streak() {
  # count of CALL: lines logged so far
  grep -c '^CALL:' "$CALL_LOG" 2>/dev/null || true
}

# Run streaks 1-5: only streak=3 delivers (plain, no --comment) -- already
# covered by ac7_ac10, re-driven here so the running total below is exact.
for i in 1 2 3 4 5; do
  CLAUDE_BIN="$FAKE_CLAUDE" "$SCRIPT" >/dev/null 2>&1
done
calls_after_5="$(calls_at_streak)"
if [ "$calls_after_5" -eq 1 ] && grep -q -- '--value 3' "$CALL_LOG" && ! grep -q -- '--comment' "$CALL_LOG"; then
  echo "ok  AC10: exactly one plain call through streak=5 (at streak=3)"
else
  echo "FAIL: expected exactly one plain --value 3 call by streak=5, got $calls_after_5:"
  cat "$CALL_LOG"
  fail=1
fi

# streak=6: --comment re-delivery with --value 6.
CLAUDE_BIN="$FAKE_CLAUDE" "$SCRIPT" >/dev/null 2>&1
calls_after_6="$(calls_at_streak)"
if [ "$calls_after_6" -eq 2 ] && tail -n1 "$CALL_LOG" | grep -q -- '--value 6' && tail -n1 "$CALL_LOG" | grep -q -- '--comment'; then
  echo "ok  AC10: streak=6 delivers --comment --value 6"
else
  echo "FAIL: expected a 2nd call with --comment --value 6 at streak=6, got $calls_after_6:"
  cat "$CALL_LOG"
  fail=1
fi

# streak=7 through 11: no further calls.
for i in 7 8 9 10 11; do
  CLAUDE_BIN="$FAKE_CLAUDE" "$SCRIPT" >/dev/null 2>&1
done
calls_after_11="$(calls_at_streak)"
if [ "$calls_after_11" -eq 2 ]; then
  echo "ok  AC10: no calls made for streaks 7 through 11"
else
  echo "FAIL: expected still 2 calls through streak=11, got $calls_after_11:"
  cat "$CALL_LOG"
  fail=1
fi

# streak=12: one more --comment re-delivery with --value 12.
CLAUDE_BIN="$FAKE_CLAUDE" "$SCRIPT" >/dev/null 2>&1
calls_after_12="$(calls_at_streak)"
if [ "$calls_after_12" -eq 3 ] && tail -n1 "$CALL_LOG" | grep -q -- '--value 12' && tail -n1 "$CALL_LOG" | grep -q -- '--comment'; then
  echo "ok  AC10: streak=12 delivers one more --comment --value 12"
else
  echo "FAIL: expected a 3rd call with --comment --value 12 at streak=12, got $calls_after_12:"
  cat "$CALL_LOG"
  fail=1
fi

exit "$fail"
