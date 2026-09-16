#!/usr/bin/env bash
# tests/canary_ac21_ac23_select_tick_knob_alarm.sh —
# PRD-build-burst-gate-canary-invariant R17/AC21/AC23.
#
# AC21: given BUILD_BURST_ENABLED=1 in the systemd drop-in and no
# state/burst-lane/enable.json, select-tick.sh journals
# `ALARM burst-knob-unsanctioned (source=burst.conf)`, delivers it through
# alert-deliver.sh under rule gate-red, and the tick's own counts.burst_session
# comes back 0 even though the fake burst probe reports gate_ready=true.
#
# AC23: given an enable.json whose canary_ts is 25h old (canary_verdict=pass
# otherwise), the alarm fires with cause=canary-stale and routing is off.
#
# Regression guard: a FRESH enable.json with canary_verdict=pass raises no
# alarm at all, even with the knob at 1 (this is the AC22 "quiet tick"
# shape, exercised end-to-end via cmd_enable in canary_ac22_*.sh — this
# file only checks select-tick.sh's own read side in isolation).
#
# Pure fixture: no real box, no hcloud/gh network call, no real cargo/gate
# work — select-tick.sh's own scan-prds.sh call runs against an empty
# build-queue/, which is a legal (zero-candidate) tick.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ST="$HERE/../scripts/select-tick.sh"
JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"
[ -x "$ST" ] || { echo "canary_ac21_ac23: $ST missing" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canary-ac21ac23.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/build-queue" "$ROOT/built-prds" "$ROOT/visions" "$ROOT/state" "$ROOT/state/burst-lane"
echo '{"prds":{}}' > "$ROOT/state/manifest.json"

JOURNAL="$ROOT/journal.md"; : > "$JOURNAL"

FAKE_BURST="$ROOT/fake-burst-lane.sh"
cat > "$FAKE_BURST" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "status" ] && { printf '{"gate_ready":true,"width":4}\n'; exit 0; }
echo '{}'
EOF
chmod +x "$FAKE_BURST"

DROPIN="$ROOT/burst.conf"
ENVFILE="$ROOT/wm-burst.env"
BURST_STATE="$ROOT/state/burst-lane"

ALERT_CALLS="$ROOT/alert-calls.log"
FAKE_ALERT="$ROOT/fake-alert-deliver.sh"
cat > "$FAKE_ALERT" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ALERT_CALLS"
exit 0
EOF
chmod +x "$FAKE_ALERT"

run_seltick() {
  BUILD_STATE_DIR="$ROOT/state" BUILD_MANIFEST="$ROOT/state/manifest.json" \
    SELECT_TICK_JOURNAL="$JOURNAL" \
    BURST_LANE_SH="$FAKE_BURST" \
    BURST_LANE_SYSTEMD_DROPIN="$DROPIN" BURST_LANE_ENV_FILE="$ENVFILE" \
    BURST_LANE_STATE_DIR="$BURST_STATE" ALERT_DELIVER="$FAKE_ALERT" \
    "$ST" --prd-dir "$ROOT" --format json "$@"
}

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi; }

echo "=== AC21: knob=1 in the drop-in, no enable.json -> ALARM (source=burst.conf), burst_session forced 0 ==="
printf '[Service]\nEnvironment=BUILD_BURST_ENABLED=1\n' > "$DROPIN"
rm -f "$ENVFILE" "$BURST_STATE/enable.json"
: > "$JOURNAL"; : > "$ALERT_CALLS"
out="$(run_seltick)"; rc=$?
expect "AC21: exit 0 (alarm is not fatal to the tick)" "[ $rc -eq 0 ]"
expect "AC21: journal carries the exact alarm string" \
  "grep -qF 'ALARM burst-knob-unsanctioned (source=burst.conf)' '$JOURNAL'"
expect "AC21: alert-deliver invoked with rule=gate-red repo=build-loop" \
  "grep -qE '^gate-red build-loop ' '$ALERT_CALLS'"
bs="$(printf '%s' "$out" | "$JQ" '.counts.burst_session')"
expect "AC21: counts.burst_session forced to 0 despite gate_ready=true" "[ '$bs' = '0' ]"

echo "=== AC23: enable.json present, canary_verdict=pass, canary_ts 25h old -> ALARM cause=canary-stale ==="
mkdir -p "$BURST_STATE"
stale_ts="$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-25H +%Y-%m-%dT%H:%M:%SZ)"
cat > "$BURST_STATE/enable.json" <<EOF
{"ts":"$stale_ts","canary_verdict":"pass","canary_ts":"$stale_ts","head":"deadbeef"}
EOF
: > "$JOURNAL"; : > "$ALERT_CALLS"
out="$(run_seltick)"; rc=$?
expect "AC23: exit 0" "[ $rc -eq 0 ]"
expect "AC23: journal carries cause=canary-stale" \
  "grep -qF 'ALARM burst-knob-unsanctioned (source=burst.conf cause=canary-stale)' '$JOURNAL'"
bs="$(printf '%s' "$out" | "$JQ" '.counts.burst_session')"
expect "AC23: counts.burst_session forced to 0" "[ '$bs' = '0' ]"

echo "=== Regression guard: fresh enable.json, canary_verdict=pass -> no alarm at all ==="
now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$BURST_STATE/enable.json" <<EOF
{"ts":"$now_ts","canary_verdict":"pass","canary_ts":"$now_ts","head":"deadbeef"}
EOF
: > "$JOURNAL"; : > "$ALERT_CALLS"
out="$(run_seltick)"; rc=$?
expect "quiet: exit 0" "[ $rc -eq 0 ]"
expect "quiet: no ALARM line journaled" "! grep -q 'burst-knob-unsanctioned' '$JOURNAL'"
expect "quiet: alert-deliver never invoked" "[ ! -s '$ALERT_CALLS' ]"
bs="$(printf '%s' "$out" | "$JQ" '.counts.burst_session')"
expect "quiet: counts.burst_session reflects the real probe (1)" "[ '$bs' = '1' ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canary_ac21_ac23_select_tick_knob_alarm: ALL PASS"
  exit 0
else
  echo "canary_ac21_ac23_select_tick_knob_alarm: assertion(s) FAILED"
  exit 1
fi
