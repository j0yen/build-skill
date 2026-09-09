#!/usr/bin/env bash
# three-state_ac2_streak_alarm_once.sh — PRD-build-three-state-probes AC2.
#
# Given 3 consecutive could-not-check emits for one probe, when the third
# lands, then exactly one probe-dead journal line and one docket report are
# produced, and a 4th emit produces no duplicate alarm.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../scripts/probe-result.sh"
[ -r "$LIB" ] || { echo "ac2: $LIB not found" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ts-ac2.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_STATE_DIR="$T/state"
export PROBE_JOURNAL_DIR="$T/journal"
export PROBE_STREAK_ALARM=3

# Fake docket on PATH so the docket-report leg is exercised offline too.
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
DOCKET_LOG="$T/docket-calls.log"
cat > "$FAKEBIN/docket" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$DOCKET_LOG"
exit 0
EOF
chmod +x "$FAKEBIN/docket"
export PATH="$FAKEBIN:$PATH"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# shellcheck source=../scripts/probe-result.sh
source "$LIB"

probe_emit alarm-demo could-not-check "attempt 1" >/dev/null
probe_emit alarm-demo could-not-check "attempt 2" >/dev/null
probe_emit alarm-demo could-not-check "attempt 3" >/dev/null

journal="$PROBE_JOURNAL_DIR/$(date -u +%F).md"
expect "journal exists after 3rd could-not-check" "[ -f '$journal' ]"
expect "exactly one probe-dead line after 3rd emit" \
  "[ \"\$(grep -c 'probe-dead: alarm-demo' '$journal')\" -eq 1 ]"
expect "docket was called exactly once" \
  "[ \"\$(grep -c 'probe-dead-alarm-demo' \"$DOCKET_LOG\")\" -eq 1 ]"

probe_emit alarm-demo could-not-check "attempt 4" >/dev/null
expect "4th emit produces no duplicate alarm (journal still has 1 line)" \
  "[ \"\$(grep -c 'probe-dead: alarm-demo' '$journal')\" -eq 1 ]"
expect "4th emit calls docket no additional time" \
  "[ \"\$(grep -c 'probe-dead-alarm-demo' \"$DOCKET_LOG\")\" -eq 1 ]"
expect "streak after 4th emit is 4" "[ \"\$(probe_streak alarm-demo)\" -eq 4 ]"

exit $fail
