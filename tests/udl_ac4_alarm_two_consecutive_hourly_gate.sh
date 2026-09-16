#!/usr/bin/env bash
# udl_ac4_alarm_two_consecutive_hourly_gate.sh —
# PRD-build-tick-under-dispatch-ledger AC4.
#
# Given two consecutive fixture ticks both under-dispatched, When the
# second reconciles, Then one `alarm … (class=under-dispatch …)` line
# exists and a fake NOTIFY_CMD recorded exactly one invocation; a third
# under-dispatched tick within the hour adds no second alarm.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"
JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
export TICK_RUN_LANE="testlane"
mkdir -p "$BUILD_STATE_DIR"

NOTIFY_LOG="$TMP/notify-calls.log"
: > "$NOTIFY_LOG"
NOTIFY_RECORD="$TMP/notify-record.sh"
cat > "$NOTIFY_RECORD" <<EOF
#!/usr/bin/env bash
cat >/dev/null
echo called >> "$NOTIFY_LOG"
exit 0
EOF
chmod +x "$NOTIFY_RECORD"
export NOTIFY_CMD="$NOTIFY_RECORD"

make_fake_coord() {
  # make_fake_coord <path> <dispatch-suffix> — 4 admitted (p,q,r,s), only p
  # and q ever get a lock.pid touch, so every tick under-dispatches 2 of 4.
  local path="$1"
  cat > "$path" <<EOF
#!/usr/bin/env bash
set -uo pipefail
JQ="$JQ"
mkdir -p "\$BUILD_STATE_DIR/select-tick"
"\$JQ" -n '{admitted:[
  {slug:"p",path:"$TMP/p.md"},
  {slug:"q",path:"$TMP/q.md"},
  {slug:"r",path:"$TMP/r.md"},
  {slug:"s",path:"$TMP/s.md"}
], skipped:[], pinned:[], counts:{pool:4,admitted:4,skipped:0,cap:30,distinct_targets:0,burst_session:0,sub_cap:1}}' \\
  > "\$BUILD_STATE_DIR/select-tick/\$SELECT_TICK_TICK_ID.json"
: > "\$BUILD_STATE_DIR/prd-p.lock.pid"
: > "\$BUILD_STATE_DIR/prd-q.lock.pid"
exit 0
EOF
  chmod +x "$path"
}

fail=0

for i in 1 2 3; do
  fc="$TMP/fake-coord-$i.sh"
  make_fake_coord "$fc"
  out="$("$SCRIPT" -- "$fc" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: tick $i exit=$rc (output: $out)"; fail=1; }
done

n_alarm=$(grep -cE '  testlane  alarm  under-dispatched twice .*class=under-dispatch lane=testlane' "$TICK_RUN_JOURNAL" 2>/dev/null); n_alarm=${n_alarm:-0}
if [ "$n_alarm" -eq 1 ]; then
  echo "ok  AC4: exactly one alarm line across three under-dispatched ticks"
else
  echo "FAIL: expected exactly one alarm line, got $n_alarm; journal:"
  cat "$TICK_RUN_JOURNAL" 2>/dev/null
  fail=1
fi

n_notify=$(grep -c 'called' "$NOTIFY_LOG" 2>/dev/null); n_notify=${n_notify:-0}
if [ "$n_notify" -eq 1 ]; then
  echo "ok  AC4: fake NOTIFY_CMD recorded exactly one invocation"
else
  echo "FAIL: expected exactly one NOTIFY_CMD invocation, got $n_notify"
  fail=1
fi

exit "$fail"
