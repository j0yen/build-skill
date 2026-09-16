#!/usr/bin/env bash
# udl_ac3_full_dispatch_mixed_evidence.sh —
# PRD-build-tick-under-dispatch-ledger AC3.
#
# Given 4 admitted and a fake coordinator that dispatches all 4 (two via
# lock.pid, one via an appended iter_log line, one via a `build  prd`
# journal line), When it exits, Then no under-dispatched line is written
# and `--status` prints `admitted=4 dispatched=4 missing=`.
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

echo "# PRD: g" > "$TMP/g.md"

FAKE_COORD="$TMP/fake-coord.sh"
cat > "$FAKE_COORD" <<EOF
#!/usr/bin/env bash
set -uo pipefail
JQ="$JQ"
mkdir -p "\$BUILD_STATE_DIR/select-tick"
"\$JQ" -n '{admitted:[
  {slug:"e",path:"$TMP/e.md"},
  {slug:"f",path:"$TMP/f.md"},
  {slug:"g",path:"$TMP/g.md"},
  {slug:"h",path:"$TMP/h.md"}
], skipped:[], pinned:[], counts:{pool:4,admitted:4,skipped:0,cap:30,distinct_targets:0,burst_session:0,sub_cap:1}}' \\
  > "\$BUILD_STATE_DIR/select-tick/\$SELECT_TICK_TICK_ID.json"
: > "\$BUILD_STATE_DIR/prd-e.lock.pid"
: > "\$BUILD_STATE_DIR/prd-f.lock.pid"
printf '\n- iter_log: %s dispatched\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TMP/g.md"
printf '%s  build  prd  h  dispatched\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "\$TICK_RUN_JOURNAL"
exit 0
EOF
chmod +x "$FAKE_COORD"

out="$("$SCRIPT" -- "$FAKE_COORD" 2>&1)"
rc=$?

fail=0
[ "$rc" -eq 0 ] || { echo "FAIL: tick-run exit=$rc, want 0 (output: $out)"; fail=1; }

n_ud=$(grep -cE '  select-tick  under-dispatched' "$TICK_RUN_JOURNAL" 2>/dev/null); n_ud=${n_ud:-0}
if [ "$n_ud" -eq 0 ]; then
  echo "ok  AC3: no under-dispatched line written"
else
  echo "FAIL: expected zero under-dispatched lines, got $n_ud; journal:"
  cat "$TICK_RUN_JOURNAL" 2>/dev/null
  fail=1
fi

status_out="$("$SCRIPT" --status)"
if printf '%s\n' "$status_out" | grep -qE '^admitted=4 dispatched=4 missing=$'; then
  echo "ok  AC3: --status prints admitted=4 dispatched=4 missing="
else
  echo "FAIL: --status output missing expected reconciliation line: $status_out"
  fail=1
fi

exit "$fail"
