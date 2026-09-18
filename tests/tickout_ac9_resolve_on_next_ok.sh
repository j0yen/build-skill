#!/usr/bin/env bash
# tickout_ac9_resolve_on_next_ok.sh —
# PRD-buildloop-tick-outcome-liveness AC9.
#
# Given a delivered loop-tick-failed alarm and then an ok tick, When the
# ok tick finishes, Then alert-deliver.sh resolve loop-tick-failed
# build-loop is called exactly once and the journal carries the resolve
# line (alert-deliver.sh's own resolve subcommand journals that line —
# see its header; this test uses the REAL alert-deliver.sh for the
# resolve call specifically, to prove that line actually lands, and a
# fake for the delivery call to keep the failing-streak half
# deterministic/offline).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
mkdir -p "$BUILD_STATE_DIR"

REAL_ALERT_DELIVER="$HERE/../scripts/alert-deliver.sh"
CALL_LOG="$TMP/alert-calls.log"
: > "$CALL_LOG"
# A dispatcher fake: delivery calls (rule != resolve arg1) are logged and
# swallowed (offline, no gh/notify-send); a `resolve` call is forwarded to
# the REAL alert-deliver.sh so its own journal-writing is exercised for
# real, under this test's own BUILD_STATE_DIR/TICK_RUN_JOURNAL.
FAKE_ALERT="$TMP/fake-alert-deliver.sh"
cat > "$FAKE_ALERT" <<EOF
#!/usr/bin/env bash
echo "CALL: \$*" >> "$CALL_LOG"
if [ "\${1:-}" = "resolve" ]; then
  exec "$REAL_ALERT_DELIVER" "\$@"
fi
exit 0
EOF
chmod +x "$FAKE_ALERT"
export TICK_RUN_ALERT_DELIVER="$FAKE_ALERT"

FAKE_FAIL="$TMP/fake-fail.sh"
cat > "$FAKE_FAIL" <<'EOF'
#!/usr/bin/env bash
echo "boom" >&2
exit 1
EOF
chmod +x "$FAKE_FAIL"

FAKE_OK="$TMP/fake-ok.sh"
cat > "$FAKE_OK" <<'EOF'
#!/usr/bin/env bash
echo "all good"
exit 0
EOF
chmod +x "$FAKE_OK"

for i in 1 2 3; do
  CLAUDE_BIN="$FAKE_FAIL" "$SCRIPT" >/dev/null 2>&1
done

resolve_calls_before="$(grep -c '^CALL: resolve' "$CALL_LOG")"
[ "$resolve_calls_before" -eq 0 ] || { echo "FAIL: resolve called before any ok tick"; exit 1; }

CLAUDE_BIN="$FAKE_OK" "$SCRIPT" >/dev/null 2>&1

fail=0
resolve_calls="$(grep -c '^CALL: resolve loop-tick-failed build-loop' "$CALL_LOG")"
if [ "$resolve_calls" -eq 1 ]; then
  echo "ok  AC9: resolve loop-tick-failed build-loop called exactly once"
else
  echo "FAIL: resolve called $resolve_calls times, want 1:"
  cat "$CALL_LOG"
  fail=1
fi

if grep -qE 'build-loop  alert-resolved  loop-tick-failed' "$TICK_RUN_JOURNAL"; then
  echo "ok  AC9: journal carries the resolve line"
else
  echo "FAIL: journal missing the resolve line; contents:"
  cat "$TICK_RUN_JOURNAL"
  fail=1
fi

# A second ok tick must not resolve again (nothing to resolve).
CLAUDE_BIN="$FAKE_OK" "$SCRIPT" >/dev/null 2>&1
resolve_calls2="$(grep -c '^CALL: resolve loop-tick-failed build-loop' "$CALL_LOG")"
if [ "$resolve_calls2" -eq 1 ]; then
  echo "ok  AC9: a second ok tick does not resolve again"
else
  echo "FAIL: resolve called $resolve_calls2 times after a second ok tick, want 1"
  fail=1
fi

exit "$fail"
