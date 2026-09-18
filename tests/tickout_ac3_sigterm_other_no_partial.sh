#!/usr/bin/env bash
# tickout_ac3_sigterm_other_no_partial.sh —
# PRD-buildloop-tick-outcome-liveness AC3.
#
# Given a child killed by SIGTERM mid-run, When tick-run.sh exits, Then a
# record exists with outcome=failed cause=other and rc=143; no partial
# JSON is ever observable (this codepath uses atomic_write_json's
# temp+rename, same as every other writer in this script — this test
# proves the record VALUE is right; the temp+rename mechanism itself is
# shared, untouched code already covered by udl_ac8's concurrent-reader
# proof for the same helper).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"
JQ="${JQ:-jq}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
mkdir -p "$BUILD_STATE_DIR"

# The fake coordinator kills ITSELF with an untrapped SIGTERM mid-run --
# this is the actual "child killed by SIGTERM" the AC describes. Signaling
# tick-run.sh's own PID from outside would kill the WRAPPER (default
# SIGTERM terminates bash immediately, before it ever reaches the
# write_tick_outcome/reconcile code after the pipeline) rather than the
# coordinator child tick-run.sh execs — that path can never produce this
# AC's record, so this test doesn't take it.
FAKE_CLAUDE="$TMP/fake-claude.sh"
cat > "$FAKE_CLAUDE" <<'EOF'
#!/usr/bin/env bash
echo "starting up"
sleep 1
kill -TERM $$
sleep 5
EOF
chmod +x "$FAKE_CLAUDE"

CLAUDE_BIN="$FAKE_CLAUDE" "$SCRIPT" >/dev/null 2>&1

fail=0
OUT="$BUILD_STATE_DIR/tick-outcome.json"
[ -f "$OUT" ] || { echo "FAIL: $OUT not written after SIGTERM"; exit 1; }

if ! "$JQ" -e . "$OUT" >/dev/null 2>&1; then
  echo "FAIL: $OUT is not valid JSON (partial write observed)"
  cat "$OUT"
  exit 1
fi
echo "ok  AC3: record is valid, complete JSON"

outcome="$("$JQ" -r '.outcome' "$OUT")"
cause="$("$JQ" -r '.cause' "$OUT")"
record_rc="$("$JQ" -r '.rc' "$OUT")"

[ "$outcome" = failed ] && echo "ok  AC3: outcome=failed" || { echo "FAIL: outcome=$outcome want failed"; fail=1; }
[ "$cause" = other ] && echo "ok  AC3: cause=other" || { echo "FAIL: cause=$cause want other"; fail=1; }
[ "$record_rc" = 143 ] && echo "ok  AC3: rc=143" || { echo "FAIL: rc=$record_rc want 143"; fail=1; }

exit "$fail"
