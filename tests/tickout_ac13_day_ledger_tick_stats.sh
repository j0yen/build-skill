#!/usr/bin/env bash
# tickout_ac13_day_ledger_tick_stats.sh —
# PRD-buildloop-tick-outcome-liveness AC13.
#
# Given a day with records ok,ok,failed(auth),failed(auth),ok, When
# day-ledger.sh runs against fixtures, Then the ledger has
# ticks_failed=2, causes={"auth-expired":2}, longest_failed_streak=2.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DL="$HERE/../scripts/day-ledger.sh"
JQ="${JQ:-jq}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIXTURE_DATE="2030-06-15"
PRD_DIR="$TMP/prds"
mkdir -p "$PRD_DIR/notes/day-ledger"
git -C "$PRD_DIR" init -q 2>/dev/null || true

TOF="$TMP/tick-outcomes.jsonl"
# ts values at noon UTC on the fixture date -- safely inside the
# America/New_York calendar day regardless of DST offset.
cat > "$TOF" <<EOF
{"ts":"${FIXTURE_DATE}T12:00:00Z","n":1,"rc":0,"outcome":"ok","cause":null,"evidence":null,"streak_failed":0,"last_ok_ts":"${FIXTURE_DATE}T12:00:00Z","lane":"redbaron"}
{"ts":"${FIXTURE_DATE}T12:05:00Z","n":2,"rc":0,"outcome":"ok","cause":null,"evidence":null,"streak_failed":0,"last_ok_ts":"${FIXTURE_DATE}T12:05:00Z","lane":"redbaron"}
{"ts":"${FIXTURE_DATE}T12:10:00Z","n":3,"rc":1,"outcome":"failed","cause":"auth-expired","evidence":"x","streak_failed":1,"last_ok_ts":"${FIXTURE_DATE}T12:05:00Z","lane":"redbaron"}
{"ts":"${FIXTURE_DATE}T12:15:00Z","n":4,"rc":1,"outcome":"failed","cause":"auth-expired","evidence":"x","streak_failed":2,"last_ok_ts":"${FIXTURE_DATE}T12:05:00Z","lane":"redbaron"}
{"ts":"${FIXTURE_DATE}T12:20:00Z","n":5,"rc":0,"outcome":"ok","cause":null,"evidence":null,"streak_failed":0,"last_ok_ts":"${FIXTURE_DATE}T12:20:00Z","lane":"redbaron"}
EOF

OUT="$TMP/ledger.json"
env PRD_DIR="$PRD_DIR" \
    DAY_LEDGER_TICK_OUTCOMES_FILE="$TOF" \
    DAY_LEDGER_MANIFEST_FILE="$TMP/nonexistent-manifest.json" \
    DAY_LEDGER_DECISIONS_FILE="$TMP/nonexistent-decisions.jsonl" \
    DAY_LEDGER_BRANCH_PROT_FILE="$TMP/nonexistent-bp.json" \
    DAY_LEDGER_JOURNAL_DIR="$TMP/journal" \
    DAY_LEDGER_JOURNALCTL_BIN="/nonexistent/journalctl" \
    DAY_LEDGER_BURST_LANE_BIN="/nonexistent/burst-lane.sh" \
    BUILD_JOURNAL_ROOT="$TMP/brain-journal" \
    BUILD_STATE_DIR="$TMP/state" \
    bash "$DL" --date "$FIXTURE_DATE" --no-push --out "$OUT" >"$TMP/dl.log" 2>&1

fail=0
if [ -f "$OUT" ]; then
  echo "ok  AC13: day-ledger.sh wrote the ledger file"
else
  echo "FAIL: $OUT not written; log:"
  cat "$TMP/dl.log"
  exit 1
fi

ticks_failed="$("$JQ" -r '.ticks_failed' "$OUT")"
causes="$("$JQ" -c '.causes' "$OUT")"
longest="$("$JQ" -r '.longest_failed_streak' "$OUT")"

[ "$ticks_failed" = 2 ] && echo "ok  AC13: ticks_failed=2" || { echo "FAIL: ticks_failed=$ticks_failed want 2"; fail=1; }
[ "$causes" = '{"auth-expired":2}' ] && echo "ok  AC13: causes={\"auth-expired\":2}" || { echo "FAIL: causes=$causes want {\"auth-expired\":2}"; fail=1; }
[ "$longest" = 2 ] && echo "ok  AC13: longest_failed_streak=2" || { echo "FAIL: longest_failed_streak=$longest want 2"; fail=1; }

exit "$fail"
