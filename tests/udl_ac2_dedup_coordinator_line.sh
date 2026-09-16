#!/usr/bin/env bash
# udl_ac2_dedup_coordinator_line.sh —
# PRD-build-tick-under-dispatch-ledger AC2.
#
# Given the same 4-admitted/2-claimed fixture but the fake coordinator ALSO
# writes its own `select-tick  under-dispatched … cause=concurrent-
# subagent-limit-20` line, When the child exits, Then the journal has one
# `under-dispatched` line (the coordinator's, untouched) and one
# `under-dispatched-detail` line carrying `missing=`; never two
# `under-dispatched` lines.
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
printf '%s  select-tick  under-dispatched  (admitted=4 dispatched=2 missing=c,d cause=concurrent-subagent-limit-20 lane=testlane)\n' \\
  "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "\$TICK_RUN_JOURNAL"
exit 0
EOF
chmod +x "$FAKE_COORD"

out="$("$SCRIPT" -- "$FAKE_COORD" 2>&1)"
rc=$?

fail=0
[ "$rc" -eq 0 ] || { echo "FAIL: tick-run exit=$rc, want 0 (output: $out)"; fail=1; }

n_ud=$(grep -cE '  select-tick  under-dispatched  ' "$TICK_RUN_JOURNAL" 2>/dev/null); n_ud=${n_ud:-0}
if [ "$n_ud" -eq 1 ]; then
  echo "ok  AC2: exactly one under-dispatched line (the coordinator's)"
else
  echo "FAIL: expected exactly one under-dispatched line, got $n_ud; journal:"
  cat "$TICK_RUN_JOURNAL" 2>/dev/null
  fail=1
fi

if grep -qE '  select-tick  under-dispatched  \(admitted=4 dispatched=2 missing=c,d cause=concurrent-subagent-limit-20 lane=testlane\)' "$TICK_RUN_JOURNAL" 2>/dev/null; then
  echo "ok  AC2: the coordinator's own cause is left untouched"
else
  echo "FAIL: coordinator's own line missing/altered; journal:"
  cat "$TICK_RUN_JOURNAL" 2>/dev/null
  fail=1
fi

n_detail=$(grep -cE '  select-tick  under-dispatched-detail  \(missing=c,d\)' "$TICK_RUN_JOURNAL" 2>/dev/null); n_detail=${n_detail:-0}
if [ "$n_detail" -eq 1 ]; then
  echo "ok  AC2: exactly one under-dispatched-detail line carrying missing=c,d"
else
  echo "FAIL: expected exactly one under-dispatched-detail line, got $n_detail; journal:"
  cat "$TICK_RUN_JOURNAL" 2>/dev/null
  fail=1
fi

exit "$fail"
