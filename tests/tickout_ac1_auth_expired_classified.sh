#!/usr/bin/env bash
# tickout_ac1_auth_expired_classified.sh —
# PRD-buildloop-tick-outcome-liveness AC1.
#
# Given a coordinator child that exits 1 after printing "Failed to
# authenticate: OAuth session expired and could not be refreshed", When
# tick-run.sh finishes, Then state/tick-outcome.json has
# outcome=failed cause=auth-expired streak_failed=1, evidence holds that
# line, and last_ok_ts equals the previous record's last_ok_ts (here:
# null, since there is no previous record).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"
JQ="${JQ:-jq}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
mkdir -p "$BUILD_STATE_DIR"

FAKE_CLAUDE="$TMP/fake-claude.sh"
cat > "$FAKE_CLAUDE" <<'EOF'
#!/usr/bin/env bash
echo "Failed to authenticate: OAuth session expired and could not be refreshed" >&2
exit 1
EOF
chmod +x "$FAKE_CLAUDE"

CLAUDE_BIN="$FAKE_CLAUDE" "$SCRIPT" >/dev/null 2>&1
rc=$?

fail=0
OUT="$BUILD_STATE_DIR/tick-outcome.json"

if [ ! -f "$OUT" ]; then
  echo "FAIL: $OUT not written (tick-run.sh exit=$rc)"
  exit 1
fi

outcome="$("$JQ" -r '.outcome' "$OUT")"
cause="$("$JQ" -r '.cause' "$OUT")"
streak="$("$JQ" -r '.streak_failed' "$OUT")"
evidence="$("$JQ" -r '.evidence' "$OUT")"
last_ok="$("$JQ" -r '.last_ok_ts' "$OUT")"
record_rc="$("$JQ" -r '.rc' "$OUT")"

[ "$outcome" = failed ] && echo "ok  AC1: outcome=failed" || { echo "FAIL: outcome=$outcome want failed"; fail=1; }
[ "$cause" = auth-expired ] && echo "ok  AC1: cause=auth-expired" || { echo "FAIL: cause=$cause want auth-expired"; fail=1; }
[ "$streak" = 1 ] && echo "ok  AC1: streak_failed=1" || { echo "FAIL: streak_failed=$streak want 1"; fail=1; }
[ "$record_rc" = 1 ] && echo "ok  AC1: rc=1" || { echo "FAIL: rc=$record_rc want 1"; fail=1; }
if printf '%s' "$evidence" | grep -q "Failed to authenticate: OAuth session expired"; then
  echo "ok  AC1: evidence holds the auth line"
else
  echo "FAIL: evidence=$evidence missing the auth line"
  fail=1
fi
[ "$last_ok" = null ] && echo "ok  AC1: last_ok_ts=null (no previous record)" || { echo "FAIL: last_ok_ts=$last_ok want null"; fail=1; }

exit "$fail"
