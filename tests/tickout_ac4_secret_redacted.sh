#!/usr/bin/env bash
# tickout_ac4_secret_redacted.sh — PRD-buildloop-tick-outcome-liveness AC4.
#
# Given stderr containing a token-shaped string sk-ant-oat01-..., When the
# record is written, Then evidence contains <redacted> and the record
# file contains no sk-ant- substring anywhere.
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
echo "leaked token sk-ant-oat01-AbCdEf1234567890_-xyz in the clear" >&2
exit 1
EOF
chmod +x "$FAKE_CLAUDE"

CLAUDE_BIN="$FAKE_CLAUDE" "$SCRIPT" >/dev/null 2>&1

fail=0
OUT="$BUILD_STATE_DIR/tick-outcome.json"
[ -f "$OUT" ] || { echo "FAIL: $OUT not written"; exit 1; }

evidence="$("$JQ" -r '.evidence' "$OUT")"
if printf '%s' "$evidence" | grep -q '<redacted>'; then
  echo "ok  AC4: evidence contains <redacted>"
else
  echo "FAIL: evidence=$evidence missing <redacted>"
  fail=1
fi

if grep -q 'sk-ant-' "$OUT"; then
  echo "FAIL: record file still contains an sk-ant- substring:"
  cat "$OUT"
  fail=1
else
  echo "ok  AC4: record file contains no sk-ant- substring"
fi

exit "$fail"
