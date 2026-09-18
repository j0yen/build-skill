#!/usr/bin/env bash
# tickout_ac2_ok_resets_streak.sh —
# PRD-buildloop-tick-outcome-liveness AC2.
#
# Given a child that exits 0, When the tick finishes, Then the record has
# outcome=ok streak_failed=0 and last_ok_ts equals this record's own ts.
# Run after a prior failed record to prove ok actually RESETS a nonzero
# streak, not just that a fresh streak starts at 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"
JQ="${JQ:-jq}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
mkdir -p "$BUILD_STATE_DIR"

FAKE_FAIL="$TMP/fake-fail.sh"
cat > "$FAKE_FAIL" <<'EOF'
#!/usr/bin/env bash
echo "boom" >&2
exit 1
EOF
chmod +x "$FAKE_FAIL"
CLAUDE_BIN="$FAKE_FAIL" "$SCRIPT" >/dev/null 2>&1

FAKE_OK="$TMP/fake-ok.sh"
cat > "$FAKE_OK" <<'EOF'
#!/usr/bin/env bash
echo "all good"
exit 0
EOF
chmod +x "$FAKE_OK"
CLAUDE_BIN="$FAKE_OK" "$SCRIPT" >/dev/null 2>&1

fail=0
OUT="$BUILD_STATE_DIR/tick-outcome.json"
[ -f "$OUT" ] || { echo "FAIL: $OUT not written"; exit 1; }

outcome="$("$JQ" -r '.outcome' "$OUT")"
streak="$("$JQ" -r '.streak_failed' "$OUT")"
ts="$("$JQ" -r '.ts' "$OUT")"
last_ok="$("$JQ" -r '.last_ok_ts' "$OUT")"
cause="$("$JQ" -r '.cause' "$OUT")"
evidence="$("$JQ" -r '.evidence' "$OUT")"

[ "$outcome" = ok ] && echo "ok  AC2: outcome=ok" || { echo "FAIL: outcome=$outcome want ok"; fail=1; }
[ "$streak" = 0 ] && echo "ok  AC2: streak_failed reset to 0" || { echo "FAIL: streak_failed=$streak want 0"; fail=1; }
[ -n "$ts" ] && [ "$ts" = "$last_ok" ] && echo "ok  AC2: last_ok_ts == this record's ts" || { echo "FAIL: ts=$ts last_ok_ts=$last_ok, want equal"; fail=1; }
[ "$cause" = null ] && echo "ok  AC2: cause=null on ok" || { echo "FAIL: cause=$cause want null"; fail=1; }
[ "$evidence" = null ] && echo "ok  AC2: evidence=null on ok" || { echo "FAIL: evidence=$evidence want null"; fail=1; }

exit "$fail"
