#!/usr/bin/env bash
# tests/canary_ac5_ac8_enable_status_gate.sh — PRD-build-burst-gate-canary-invariant
# AC5: given proof_routed=true and canary=missing, `enable` refuses with
# cause=canary-missing and writes no drop-in; given a passing canary.json,
# a re-run writes the drop-in (and, per R17, enable.json recording the
# canary verdict/head that authorized it). AC8: `status` line 2 carries
# canary=<verdict>@<age>h head=<sha7>. Pure fixture: no real box, no hcloud
# call, no gh network call — cmd_enable/cmd_status never shell out to
# either for the fields this test exercises.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canary-ac5ac8.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
export BURST_LANE_TEST=1
export BURST_LANE_STATE_DIR="$ROOT/state"
export BURST_LANE_JOURNAL="$ROOT/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
export BURST_LANE_SYSTEMD_DROPIN="$ROOT/burst.conf"
export FAKE_HCLOUD_STATE="$ROOT/fake-hcloud.state"

STATE_DIR="$ROOT/state"
BOX_DIR="$STATE_DIR/current"
mkdir -p "$BOX_DIR"

SERVER_ID="testbox1"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# session_reconcile (cmd_status's AC6 verify-against-hcloud step) needs the
# fake hcloud's own server-list to agree this box is alive, or `status`
# archives session.json and reports active:false before ever reaching
# status_extra_fields_line -- seed one matching row (AC8 is about the
# canary field on the active-session line, not about session_reconcile
# itself).
echo "$SERVER_ID|$SERVER_ID|alive|$NOW_ISO" > "$FAKE_HCLOUD_STATE"

# Fresh box: a session, and a proof.json that would otherwise let `enable`
# through (routed=true, fresh ts, image_id matching resolve_boot_image's
# default -- no snapshot.json exists, so resolve_boot_image falls through
# to $SNAPSHOT_ID's default value, read from the script itself).
DEFAULT_SNAPSHOT_ID="$(grep -oE '^DEFAULT_SNAPSHOT_ID="[0-9]+"' "$BL" | head -n1 | grep -oE '[0-9]+')"
cat > "$BOX_DIR/session.json" <<EOF
{"server_id":"$SERVER_ID","ip":"127.0.0.1"}
EOF
cat > "$BOX_DIR/proof.json" <<EOF
{"routed":true,"ts":"$NOW_ISO","image_id":"$DEFAULT_SNAPSHOT_ID"}
EOF

echo "== AC5 part 1: canary=missing -> enable refuses, no drop-in =="
set +e
out="$("$BL" enable 2>&1)"; rc=$?
set -e
[ "$rc" -eq 3 ] || { echo "FAIL: expected exit 3, got $rc ($out)"; exit 1; }
case "$out" in
  *"cause=canary-missing"*) echo "ok  refused cause=canary-missing" ;;
  *) echo "FAIL: expected cause=canary-missing, got: $out"; exit 1 ;;
esac
[ -f "$BURST_LANE_SYSTEMD_DROPIN" ] && { echo "FAIL: drop-in written on a missing canary"; exit 1; }
echo "ok  no drop-in written"
grep -q "enable  refused  (cause=canary-missing)" "$BURST_LANE_JOURNAL" || { echo "FAIL: journal missing canary-missing line"; exit 1; }
echo "ok  journal line present"

echo "== AC5 part 2: canary=diverged -> enable refuses =="
mkdir -p "$STATE_DIR/boxes/$SERVER_ID"
cat > "$STATE_DIR/boxes/$SERVER_ID/canary.json" <<EOF
{"head":"deadbeef00","head_source":"green-main","ts":"$NOW_ISO","image_id":"$DEFAULT_SNAPSHOT_ID",
 "variants":{"main":"diverged","branch":"pass","delta":"pass"},
 "diverged":[{"producer":"extended-receipts","local":"pass","box":"fail","route":"burst:$SERVER_ID"}],
 "baseline_dir":""}
EOF
set +e
out="$("$BL" enable 2>&1)"; rc=$?
set -e
[ "$rc" -eq 3 ] || { echo "FAIL: expected exit 3, got $rc ($out)"; exit 1; }
case "$out" in
  *"cause=canary-diverged"*) echo "ok  refused cause=canary-diverged" ;;
  *) echo "FAIL: expected cause=canary-diverged, got: $out"; exit 1 ;;
esac
[ -f "$BURST_LANE_SYSTEMD_DROPIN" ] && { echo "FAIL: drop-in written on a diverged canary"; exit 1; }

echo "== AC5 part 3: canary=pass -> enable succeeds, writes drop-in + enable.json =="
cat > "$STATE_DIR/boxes/$SERVER_ID/canary.json" <<EOF
{"head":"abcdef01234567","head_source":"green-main","ts":"$NOW_ISO","image_id":"$DEFAULT_SNAPSHOT_ID",
 "variants":{"main":"pass","branch":"pass","delta":"pass"},
 "diverged":[],
 "baseline_dir":""}
EOF
set +e
out="$("$BL" enable 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "FAIL: expected exit 0, got $rc ($out)"; exit 1; }
[ -f "$BURST_LANE_SYSTEMD_DROPIN" ] || { echo "FAIL: drop-in not written on a passing canary"; exit 1; }
echo "ok  drop-in written"
[ -f "$STATE_DIR/enable.json" ] || { echo "FAIL: enable.json (R17) not written"; exit 1; }
python3 - "$STATE_DIR/enable.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("canary_verdict") == "pass", d
assert d.get("head", "").startswith("abcdef0"), d
assert d.get("ts"), d
print("ok  enable.json records canary_verdict=pass head=%s" % d.get("head"))
PYEOF

echo "== AC8: status line 2 carries canary=pass@<age>h head=<sha7> =="
status_out="$("$BL" status)"
line2="$(printf '%s\n' "$status_out" | sed -n '2p')"
case "$line2" in
  *"canary=pass@"*"h head=abcdef0"*) echo "ok  status line 2: $line2" ;;
  *) echo "FAIL: status line 2 missing canary field: $line2"; exit 1 ;;
esac

echo "canary_ac5_ac8_enable_status_gate: ALL PASS"
