#!/usr/bin/env bash
# tickout_ac8_quota_saturated_never_pages.sh —
# PRD-buildloop-tick-outcome-liveness AC8.
#
# Given three consecutive failures with cause quota-saturated, When the
# third tick finishes, Then no loop-tick-failed call is made and the
# record still shows streak_failed=3.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"
JQ="${JQ:-jq}"

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
echo "You've hit your usage limit for this plan, try again later" >&2
exit 1
EOF
chmod +x "$FAKE_CLAUDE"

for i in 1 2 3; do
  CLAUDE_BIN="$FAKE_CLAUDE" "$SCRIPT" >/dev/null 2>&1
done

fail=0
if [ -s "$CALL_LOG" ]; then
  echo "FAIL: alert-deliver called during a quota-saturated streak:"
  cat "$CALL_LOG"
  fail=1
else
  echo "ok  AC8: no loop-tick-failed call during a quota-saturated streak"
fi

streak="$("$JQ" -r '.streak_failed' "$BUILD_STATE_DIR/tick-outcome.json")"
cause="$("$JQ" -r '.cause' "$BUILD_STATE_DIR/tick-outcome.json")"
[ "$streak" = 3 ] && echo "ok  AC8: streak_failed=3" || { echo "FAIL: streak_failed=$streak want 3"; fail=1; }
[ "$cause" = quota-saturated ] && echo "ok  AC8: cause=quota-saturated" || { echo "FAIL: cause=$cause want quota-saturated"; fail=1; }

exit "$fail"
