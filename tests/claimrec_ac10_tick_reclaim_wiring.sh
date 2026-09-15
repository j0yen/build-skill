#!/usr/bin/env bash
# claimrec_ac10_tick_reclaim_wiring.sh — PRD-build-stale-claim-auto-
# recovery AC10 (P1).
#
# Given the real queue's own tick pass (manifest-invariants.sh's
# claims-stale sweep, run the same way every tick already runs it — see
# gatedebt_ac5_stale_claim_reclaimed_same_tick.sh for the sibling PRD this
# wiring shares), When a tick runs after this ships, Then any dead-pid
# claim present is reclaimed within that tick (claim released, Status +
# manifest reset to queued, together) and the PRD is selectable on the
# next one -- exercised here against a scratch manifest/PRD-dir standing
# in for "the real queue," never the real ~/Documents/PRDs clone.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MI="$HERE/../scripts/manifest-invariants.sh"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$MI" ] || { echo "ac10: $MI not executable" >&2; exit 2; }
[ -x "$LC" ] || { echo "ac10: $LC not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claimrec-ac10.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue" "$T/clone/built-prds" "$T/clone/parked"
cat > "$T/clone/build-queue/PRD-claimrec-ac10.md" <<'EOF'
# PRD: claimrec-ac10

- Status: building
- build_target: shell
- build_into: /tmp/claimrec-ac10-target
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
BR="$(git -C "$T/clone" symbolic-ref --short HEAD)"
git -C "$T/clone" push -q origin "$BR"
PRD="$T/clone/build-queue/PRD-claimrec-ac10.md"

source "$LC"
DEAD_PID=999976
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID - 1)); done
ts=$(now_iso)
write_claim "$PRD" building "$(hostname) $ts pid=$DEAD_PID boot=$(current_boot_id)"
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: claimrec-ac10 (fixture, dead pid)"
git -C "$T/clone" push -q origin "$BR"

STATE="$T/state"
mkdir -p "$STATE/intent"
python3 -c "
import json
json.dump({'prds': {'claimrec-ac10': {
  'slug': 'claimrec-ac10', 'status': 'building', 'path': '$PRD'
}}}, open('$STATE/manifest.json', 'w'))
"

export BUILD_STATE_DIR="$STATE"
export BUILD_MANIFEST="$STATE/manifest.json"
export LOCK="$STATE/tick.lock"
export JOURNAL="$T/journal.md"
export LANE_CLAIM="$LC"
: > "$JOURNAL"

# --- tick N: the sweep detects and reclaims the dead-pid claim ----------
out="$("$MI" --prd-dir "$T/clone" --format json)"; rc=$?
expect "manifest-invariants exits 0" "[ $rc -eq 0 ]"
expect "journal has the stale-claim alarm" "grep -q 'claimrec-ac10.*alarm.*claim is stale.*class=stale-claim' '$JOURNAL'"
expect "journal has the claim-reclaimed line in the SAME run" \
  "grep -q 'claimrec-ac10  claim  reclaimed  (prd=claimrec-ac10' '$JOURNAL'"

git -C "$T/clone" pull -q --rebase
expect "PRD file: Lane: line gone, Status reset to queued" \
  "! grep -q '^- Lane:' '$PRD' && grep -q '^- Status: queued' '$PRD'"

manifest_status="$(python3 -c "import json; print(json.load(open('$STATE/manifest.json'))['prds']['claimrec-ac10']['status'])")"
expect "manifest entry reset to queued in the SAME tick" "[ '$manifest_status' = queued ]"

# --- tick N+1: the reclaimed PRD is admitted (Status: queued is exactly
# what the selector's own admissibility test reads) ----------------------
status_of() {
  head -n 80 "$1" | grep -E '^(- *Status:|Status:|\*\*Status:\*\*)' | head -n1 \
    | sed -E 's/^(- *Status:|Status:|\*\*Status:\*\*)[[:space:]]*//' | awk '{print $1}'
}
expect "PRD is selectable on the next tick (Status: queued)" "[ \"\$(status_of '$PRD')\" = queued ]"

exit $fail
