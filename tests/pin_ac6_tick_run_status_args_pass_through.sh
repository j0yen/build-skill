#!/usr/bin/env bash
# pin_ac6_tick_run_status_args_pass_through.sh — PRD-build-select-tick-
# run-pin AC6.
#
# Given BUILD_TICK_ARGS="status", When tick-run.sh builds its default
# coord_cmd, Then no SELECT_TICK_PIN is exported and the coordinator
# receives "/build status" unchanged.
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

RECORD_FILE="$TMP/record.txt" \
  BUILD_STATE_DIR="$TMP/state" \
  TICK_RUN_JOURNAL="$TMP/journal.md" \
  CLAUDE_BIN="$FAKE_CLAUDE" \
  BUILD_TICK_ARGS="status" \
  "$SCRIPT"

if [ ! -f "$TMP/record.txt" ]; then
  echo "FAIL: fake coordinator never ran"
  exit 1
fi

argv_line="$(grep '^ARGV:' "$TMP/record.txt" || true)"
pin_line="$(grep '^PIN:' "$TMP/record.txt" || true)"

if [ "$argv_line" != "ARGV:-p /build status --model sonnet --dangerously-skip-permissions --output-format text" ]; then
  echo "FAIL: expected unchanged '/build status' arg, got: $argv_line"
  fail=1
fi

if [ "$pin_line" != "PIN:<unset>" ]; then
  echo "FAIL: expected SELECT_TICK_PIN to stay unset for a non-'run' BUILD_TICK_ARGS, got: $pin_line"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "ok  AC6: status passes through unchanged, no pin derived"
exit "$fail"
