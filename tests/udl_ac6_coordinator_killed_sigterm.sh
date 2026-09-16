#!/usr/bin/env bash
# udl_ac6_coordinator_killed_sigterm.sh —
# PRD-build-tick-under-dispatch-ledger AC6.
#
# Given a fake coordinator killed by SIGTERM after claiming 1 of 3, When
# the wrapper's reconciliation runs (right after the foreground child
# returns from being signaled), Then the reconciliation row reads
# dispatched=1 … cause=coordinator-killed-TERM, the holder file is gone,
# and tick.lock is free.
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

FAKE_COORD="$TMP/fake-coord.sh"
cat > "$FAKE_COORD" <<EOF
#!/usr/bin/env bash
set -uo pipefail
JQ="$JQ"
echo \$\$ > "$TMP/coord.pid"
mkdir -p "\$BUILD_STATE_DIR/select-tick"
"\$JQ" -n '{admitted:[
  {slug:"i",path:"$TMP/i.md"},
  {slug:"j",path:"$TMP/j.md"},
  {slug:"k",path:"$TMP/k.md"}
], skipped:[], pinned:[], counts:{pool:3,admitted:3,skipped:0,cap:30,distinct_targets:0,burst_session:0,sub_cap:1}}' \\
  > "\$BUILD_STATE_DIR/select-tick/\$SELECT_TICK_TICK_ID.json"
: > "\$BUILD_STATE_DIR/prd-i.lock.pid"
sleep 30
EOF
chmod +x "$FAKE_COORD"

"$SCRIPT" -- "$FAKE_COORD" >"$TMP/tickrun.out" 2>&1 &
BGPID=$!

# Wait for the fake coordinator to actually start and record its own pid.
for _ in $(seq 1 50); do
  [ -s "$TMP/coord.pid" ] && break
  sleep 0.1
done
COORDPID="$(cat "$TMP/coord.pid" 2>/dev/null || true)"

fail=0
if [ -z "$COORDPID" ]; then
  echo "FAIL: fake coordinator never recorded its own pid"
  fail=1
else
  kill -TERM "$COORDPID" 2>/dev/null
fi

wait "$BGPID" 2>/dev/null
rc=$?

if [ "$rc" -eq 143 ]; then
  echo "ok  AC6: tick-run.sh exits 143 (128+TERM), the child's own signal exit"
else
  echo "FAIL: expected tick-run.sh exit=143, got $rc (output: $(cat "$TMP/tickrun.out"))"
  fail=1
fi

recon="$("$JQ" -c . "$BUILD_STATE_DIR/select-tick/last.reconcile.json" 2>/dev/null || true)"
cause="$(printf '%s' "$recon" | "$JQ" -r '.cause // empty' 2>/dev/null)"
dispatched="$(printf '%s' "$recon" | "$JQ" -r '.dispatched // empty' 2>/dev/null)"
if [ "$cause" = "coordinator-killed-TERM" ] && [ "$dispatched" = "1" ]; then
  echo "ok  AC6: reconciliation row reads dispatched=1 cause=coordinator-killed-TERM"
else
  echo "FAIL: reconciliation row wrong: $recon"
  fail=1
fi

if [ ! -e "$BUILD_STATE_DIR/tick.lock.holder" ]; then
  echo "ok  AC6: holder file is gone"
else
  echo "FAIL: holder file still present"
  fail=1
fi

status_out="$("$SCRIPT" --status | head -1)"
if [ "$status_out" = "free" ]; then
  echo "ok  AC6: tick.lock is free"
else
  echo "FAIL: tick.lock not free: $status_out"
  fail=1
fi

exit "$fail"
