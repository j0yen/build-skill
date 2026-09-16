#!/usr/bin/env bash
# tests/canary_ac22_enable_writes_both_knobs_no_alarm.sh —
# PRD-build-burst-gate-canary-invariant R17/AC22: given `burst-lane.sh
# enable` after a canary pass (fixture), when it completes, enable.json
# records canary_verdict=pass with the canary ts and head, BOTH knob files
# (the systemd drop-in and ~/.config/wm-burst/.env, per BURST_LANE_ENV_FILE)
# read BUILD_BURST_ENABLED=1, and the next select-tick.sh tick journals no
# knob alarm. Also covers disable: a subsequent `disable` sets both files
# back to 0 (write_burst_knob_env(0), never a bare `rm` of the .env line —
# gate-launch units that source .env still need to see an explicit 0).
#
# Harness mirrors tests/canary_ac5_ac8_enable_status_gate.sh's cmd_enable
# fixture (same fake hcloud/session/proof scaffolding); pure fixture, no
# real box, no hcloud/gh network call.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"
ST="$HERE/../scripts/select-tick.sh"
JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canary-ac22.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
export BURST_LANE_TEST=1
export BURST_LANE_STATE_DIR="$ROOT/state"
export BURST_LANE_JOURNAL="$ROOT/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
export BURST_LANE_SYSTEMD_DROPIN="$ROOT/burst.conf"
export BURST_LANE_ENV_FILE="$ROOT/wm-burst.env"
export FAKE_HCLOUD_STATE="$ROOT/fake-hcloud.state"

STATE_DIR="$ROOT/state"
BOX_DIR="$STATE_DIR/current"
mkdir -p "$BOX_DIR"

# Seed wm-burst.env with an unrelated key, same shape as the real file, to
# prove write_burst_knob_env() upserts only its own line.
cat > "$BURST_LANE_ENV_FILE" <<'EOF'
export HCLOUD_SSH_KEY=wintermute-build
BUILD_BURST_ENABLED=0
EOF

SERVER_ID="testbox1"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "$SERVER_ID|$SERVER_ID|alive|$NOW_ISO" > "$FAKE_HCLOUD_STATE"

DEFAULT_SNAPSHOT_ID="$(grep -oE '^DEFAULT_SNAPSHOT_ID="[0-9]+"' "$BL" | head -n1 | grep -oE '[0-9]+')"
cat > "$BOX_DIR/session.json" <<EOF
{"server_id":"$SERVER_ID","ip":"127.0.0.1"}
EOF
cat > "$BOX_DIR/proof.json" <<EOF
{"routed":true,"ts":"$NOW_ISO","image_id":"$DEFAULT_SNAPSHOT_ID"}
EOF
mkdir -p "$STATE_DIR/boxes/$SERVER_ID"
cat > "$STATE_DIR/boxes/$SERVER_ID/canary.json" <<EOF
{"head":"abcdef01234567","head_source":"green-main","ts":"$NOW_ISO","image_id":"$DEFAULT_SNAPSHOT_ID",
 "variants":{"main":"pass","branch":"pass","delta":"pass"},
 "diverged":[],
 "baseline_dir":""}
EOF

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi; }

echo "== AC22 part 1: enable after canary pass writes both knob files =="
out="$("$BL" enable 2>&1)"; rc=$?
expect "enable exits 0" "[ $rc -eq 0 ]"
expect "drop-in reads BUILD_BURST_ENABLED=1" \
  "grep -q 'BUILD_BURST_ENABLED=1' '$BURST_LANE_SYSTEMD_DROPIN'"
expect ".env reads BUILD_BURST_ENABLED=1" \
  "grep -q '^BUILD_BURST_ENABLED=1$' '$BURST_LANE_ENV_FILE'"
expect ".env's unrelated key survives untouched" \
  "grep -q '^export HCLOUD_SSH_KEY=wintermute-build$' '$BURST_LANE_ENV_FILE'"
expect "enable.json exists" "[ -f '$STATE_DIR/enable.json' ]"
cv="$("$JQ" -r '.canary_verdict' "$STATE_DIR/enable.json")"
head="$("$JQ" -r '.head' "$STATE_DIR/enable.json")"
expect "enable.json canary_verdict=pass" "[ '$cv' = 'pass' ]"
expect "enable.json head=abcdef0..." "case '$head' in abcdef0*) true;; *) false;; esac"

echo "== AC22 part 2: next select-tick.sh tick journals no knob alarm =="
TICK_ROOT="$ROOT/tick"
mkdir -p "$TICK_ROOT/build-queue" "$TICK_ROOT/built-prds" "$TICK_ROOT/visions" "$TICK_ROOT/state" "$TICK_ROOT/state/burst-lane"
echo '{"prds":{}}' > "$TICK_ROOT/state/manifest.json"
TICK_JOURNAL="$ROOT/tick-journal.md"; : > "$TICK_JOURNAL"
FAKE_BURST="$ROOT/fake-burst-lane-for-tick.sh"
cat > "$FAKE_BURST" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "status" ] && { printf '{"gate_ready":true,"width":4}\n'; exit 0; }
echo '{}'
EOF
chmod +x "$FAKE_BURST"
# select-tick.sh's own knob-ownership check reads enable.json from
# BURST_LANE_STATE_DIR -- point it at the SAME state dir `enable` just
# wrote into, exactly as a real tick would (one shared STATE_DIR, no
# copy-out step).
tick_out="$(BUILD_STATE_DIR="$TICK_ROOT/state" BUILD_MANIFEST="$TICK_ROOT/state/manifest.json" \
  SELECT_TICK_JOURNAL="$TICK_JOURNAL" BURST_LANE_SH="$FAKE_BURST" \
  BURST_LANE_SYSTEMD_DROPIN="$BURST_LANE_SYSTEMD_DROPIN" BURST_LANE_ENV_FILE="$BURST_LANE_ENV_FILE" \
  BURST_LANE_STATE_DIR="$STATE_DIR" \
  "$ST" --prd-dir "$TICK_ROOT" --format json)"
expect "tick: no ALARM line journaled" "! grep -q 'burst-knob-unsanctioned' '$TICK_JOURNAL'"
bs="$(printf '%s' "$tick_out" | "$JQ" '.counts.burst_session')"
expect "tick: counts.burst_session reflects the real probe (1), not forced off" "[ '$bs' = '1' ]"

echo "== AC22 part 3 (disable): both knob files read 0, never a torn-out .env line =="
out="$("$BL" disable 2>&1)"; rc=$?
expect "disable exits 0" "[ $rc -eq 0 ]"
expect "drop-in removed" "[ ! -f '$BURST_LANE_SYSTEMD_DROPIN' ]"
expect ".env reads BUILD_BURST_ENABLED=0 (set, not deleted)" \
  "grep -q '^BUILD_BURST_ENABLED=0$' '$BURST_LANE_ENV_FILE'"
expect ".env's unrelated key still survives" \
  "grep -q '^export HCLOUD_SSH_KEY=wintermute-build$' '$BURST_LANE_ENV_FILE'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canary_ac22_enable_writes_both_knobs_no_alarm: ALL PASS"
  exit 0
else
  echo "canary_ac22_enable_writes_both_knobs_no_alarm: assertion(s) FAILED"
  exit 1
fi
