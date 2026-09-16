#!/usr/bin/env bash
# udl_ac1_evidence_under_dispatched.sh —
# PRD-build-tick-under-dispatch-ledger AC1.
#
# Given a fixture select-tick result with 4 admitted and a fake coordinator
# that claims only 2 of them (touches state/prd-<slug>.lock.pid), When
# tick-run.sh's child exits 0, Then the journal has exactly one
# `select-tick  under-dispatched  (admitted=4 dispatched=2 missing=c,d
# cause=unknown lane=…)` line and the wrapper exits 0.
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
mkdir -p "\$BUILD_STATE_DIR/select-tick"
"\$JQ" -n '{admitted:[
  {slug:"a",path:"$TMP/a.md"},
  {slug:"b",path:"$TMP/b.md"},
  {slug:"c",path:"$TMP/c.md"},
  {slug:"d",path:"$TMP/d.md"}
], skipped:[], pinned:[], counts:{pool:4,admitted:4,skipped:0,cap:30,distinct_targets:0,burst_session:0,sub_cap:1}}' \\
  > "\$BUILD_STATE_DIR/select-tick/\$SELECT_TICK_TICK_ID.json"
: > "\$BUILD_STATE_DIR/prd-a.lock.pid"
: > "\$BUILD_STATE_DIR/prd-b.lock.pid"
exit 0
EOF
chmod +x "$FAKE_COORD"

out="$("$SCRIPT" -- "$FAKE_COORD" 2>&1)"
rc=$?

fail=0
if [ "$rc" -eq 0 ]; then
  echo "ok  AC1: tick-run.sh exits 0 (the coordinator's own exit)"
else
  echo "FAIL: tick-run exit=$rc, want 0 (output: $out)"
  fail=1
fi

n=$(grep -cE '  select-tick  under-dispatched  ' "$TICK_RUN_JOURNAL" 2>/dev/null); n=${n:-0}
if [ "$n" -eq 1 ]; then
  echo "ok  AC1: exactly one under-dispatched line"
else
  echo "FAIL: expected exactly one under-dispatched line, got $n; journal:"
  cat "$TICK_RUN_JOURNAL" 2>/dev/null
  fail=1
fi

if grep -qE '  select-tick  under-dispatched  \(admitted=4 dispatched=2 missing=c,d cause=unknown lane=testlane\)' "$TICK_RUN_JOURNAL" 2>/dev/null; then
  echo "ok  AC1: line names admitted=4 dispatched=2 missing=c,d cause=unknown lane=testlane"
else
  echo "FAIL: journal missing expected under-dispatched shape; contents:"
  cat "$TICK_RUN_JOURNAL" 2>/dev/null
  fail=1
fi

exit "$fail"
