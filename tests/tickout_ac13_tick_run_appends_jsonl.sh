#!/usr/bin/env bash
# tickout_ac13_tick_run_appends_jsonl.sh —
# PRD-buildloop-tick-outcome-liveness R8 (tick-run.sh half of AC13):
# every tick appends one compact JSONL line to state/tick-outcomes.jsonl,
# and rotation drops lines older than TICK_OUTCOMES_ROTATE_DAYS.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"
JQ="${JQ:-jq}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
mkdir -p "$BUILD_STATE_DIR"

FAKE_OK="$TMP/fake-ok.sh"
cat > "$FAKE_OK" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_OK"

for i in 1 2 3; do
  CLAUDE_BIN="$FAKE_OK" "$SCRIPT" >/dev/null 2>&1
done

fail=0
JSONL="$BUILD_STATE_DIR/tick-outcomes.jsonl"
[ -f "$JSONL" ] || { echo "FAIL: $JSONL not written"; exit 1; }

n_lines="$(wc -l < "$JSONL" | tr -d ' ')"
[ "$n_lines" = 3 ] && echo "ok  AC13: 3 ticks -> 3 jsonl lines" || { echo "FAIL: $n_lines lines, want 3"; fail=1; }

all_valid=1
while IFS= read -r line; do
  "$JQ" -e . <<<"$line" >/dev/null 2>&1 || all_valid=0
done < "$JSONL"
[ "$all_valid" -eq 1 ] && echo "ok  AC13: every line is valid single-line JSON" || { echo "FAIL: a line is not valid JSON"; fail=1; }

# Rotation: seed an old line, run one more tick with a 1-day retention,
# then the old line must be gone.
printf '%s\n' '{"ts":"2000-01-01T00:00:00Z","n":0,"rc":0,"outcome":"ok","cause":null,"evidence":null,"streak_failed":0,"last_ok_ts":"2000-01-01T00:00:00Z","lane":"redbaron"}' >> "$JSONL"
TICK_OUTCOMES_ROTATE_DAYS=1 CLAUDE_BIN="$FAKE_OK" "$SCRIPT" >/dev/null 2>&1
if grep -q '2000-01-01' "$JSONL"; then
  echo "FAIL: rotation did not drop the old line"
  fail=1
else
  echo "ok  AC13: rotation drops a line older than the retention window"
fi

exit "$fail"
