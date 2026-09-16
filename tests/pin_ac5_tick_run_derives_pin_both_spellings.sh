#!/usr/bin/env bash
# pin_ac5_tick_run_derives_pin_both_spellings.sh — PRD-build-select-tick-
# run-pin AC5.
#
# Given BUILD_TICK_ARGS="run a b" and separately "run a,b", When
# tick-run.sh builds its default coord_cmd under a fake coordinator that
# records its own argv and the SELECT_TICK_PIN it inherited, Then both
# spellings resolve to SELECT_TICK_PIN=a,b and the coordinator's own
# /build arg carries no slug list.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0

FAKE_CLAUDE="$TMP/fake-claude.sh"
cat > "$FAKE_CLAUDE" <<'EOF'
#!/usr/bin/env bash
{
  printf 'ARGV:%s\n' "$*"
  printf 'PIN:%s\n' "${SELECT_TICK_PIN-<unset>}"
} > "$RECORD_FILE"
exit 0
EOF
chmod +x "$FAKE_CLAUDE"

run_case() {
  local args="$1" label="$2"
  local state="$TMP/state-$label"
  mkdir -p "$state"
  RECORD_FILE="$TMP/record-$label.txt" \
    BUILD_STATE_DIR="$state" \
    TICK_RUN_JOURNAL="$TMP/journal-$label.md" \
    CLAUDE_BIN="$FAKE_CLAUDE" \
    BUILD_TICK_ARGS="$args" \
    "$SCRIPT"
}

run_case "run a b" spaced
run_case "run a,b" commas

for label in spaced commas; do
  record="$TMP/record-$label.txt"
  if [ ! -f "$record" ]; then
    echo "FAIL: $label: fake coordinator never ran (no $record)"
    fail=1
    continue
  fi
  argv_line="$(grep '^ARGV:' "$record" || true)"
  pin_line="$(grep '^PIN:' "$record" || true)"

  expected_argv="ARGV:-p /build --model sonnet --dangerously-skip-permissions --output-format text"
  if [ "$argv_line" != "$expected_argv" ]; then
    echo "FAIL: $label: expected bare '/build' with no slug list, got: $argv_line"
    fail=1
  fi

  if [ "$pin_line" != "PIN:a,b" ]; then
    echo "FAIL: $label: expected PIN:a,b, got: $pin_line"
    fail=1
  fi

  if [ "$fail" -eq 0 ]; then
    echo "ok  AC5: $label spelling -> $pin_line, coordinator argv clean"
  fi
done

exit "$fail"
