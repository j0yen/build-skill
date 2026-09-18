#!/usr/bin/env bash
# tests/enablepr_ac1_proof_inherited_from_image.sh —
# PRD-build-burst-lane-enable-proof-inherited AC1: the CURRENT box has no
# proof.json but a sibling box dir under the same boxes root holds a valid
# routed=true proof.json for the boot image `enable` would use ->
# resolve_proof_file prints the sibling's path, and `enable` journals
# `enable  proof-inherited` naming it before the allow/refuse decision.
# Negative: a sibling proof for a DIFFERENT image_id never resolves. Pure
# fixture; isolation mirrors canary_ac22_enable_writes_both_knobs_no_alarm.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/enablepr-ac1.XXXXXX")"
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
OLD_ID="oldbox1"; NEW_ID="newbox1"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
IMAGE_X="$(grep -oE '^DEFAULT_SNAPSHOT_ID="[0-9]+"' "$BL" | head -n1 | grep -oE '[0-9]+')"

mkdir -p "$STATE_DIR/boxes/$OLD_ID" "$STATE_DIR/boxes/$NEW_ID"
cat > "$STATE_DIR/boxes/$OLD_ID/proof.json" <<EOF
{"routed":true,"ts":"$NOW_ISO","image_id":"$IMAGE_X","server_id":"$OLD_ID"}
EOF
ln -sfn "boxes/$NEW_ID" "$STATE_DIR/current"
echo "$NEW_ID|$NEW_ID|alive|$NOW_ISO" > "$FAKE_HCLOUD_STATE"
cat > "$STATE_DIR/boxes/$NEW_ID/session.json" <<EOF
{"server_id":"$NEW_ID","ip":"127.0.0.1"}
EOF

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL  $label" >&2; fail=1; fi; }

echo "== AC1 part 1: new box empty; resolve_proof_file inherits old sibling's =="
resolved="$("$BL" _debug-resolve-proof-file "$IMAGE_X")"
# Canonicalize -- the literal string legitimately carries an unresolved
# ".." through $BOX_STATE_DIR (the `current` symlink), by design.
old_canon="$(readlink -f "$STATE_DIR/boxes/$OLD_ID/proof.json")"
expect "resolve_proof_file X resolves to the OLD box's proof.json" \
  "[ -n '$resolved' ] && [ \"\$(readlink -f '$resolved')\" = '$old_canon' ]"
expect "the new box's own proof.json does not exist" "[ ! -f '$STATE_DIR/boxes/$NEW_ID/proof.json' ]"

echo "== AC1 part 2: enable journals proof-inherited before allow/refuse =="
set +e; out="$("$BL" enable 2>&1)"; rc=$?; set -e
expect "enable exits 3 (canary-missing downstream, not this AC's concern)" "[ $rc -eq 3 ]"
expect "journal has enable  proof-inherited with from_server/proof_ts/image_id" \
  "grep -q 'enable  proof-inherited  (from_server=$OLD_ID proof_ts=$NOW_ISO image_id=$IMAGE_X)' '$BURST_LANE_JOURNAL'"
expect "enable did not refuse with cause=no-proof" "! grep -q 'cause=no-proof' '$BURST_LANE_JOURNAL'"

echo "== AC1 negative: sibling proof for a DIFFERENT image_id never resolves =="
none="$("$BL" _debug-resolve-proof-file "999999999")"
expect "resolve_proof_file prints nothing for a mismatched image_id" "[ -z '$none' ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "enablepr_ac1_proof_inherited_from_image: ALL PASS"; exit 0
else
  echo "enablepr_ac1_proof_inherited_from_image: assertion(s) FAILED"; exit 1
fi
