#!/usr/bin/env bash
# claimrec_ac9_claims_json_distinguishes_states.sh — PRD-build-stale-claim-
# auto-recovery AC9 (P1).
#
# Given three fixture claims (live, dead-pid, over-threshold on an
# uncheckable host), When lane-claim.sh claims --json runs, Then each
# carries its distinct state (and, for the two stale variants, a distinct
# `cause`).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac9: lane-claim.sh not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ac9: jq required" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claimrec-ac9.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
source "$LC"

# live
cat > "$T/clone/build-queue/PRD-claimrec-ac9-live.md" <<'EOF'
# PRD: claimrec-ac9-live
- Status: building
- build_target: shell
EOF
# dead-pid
cat > "$T/clone/build-queue/PRD-claimrec-ac9-deadpid.md" <<'EOF'
# PRD: claimrec-ac9-deadpid
- Status: building
- build_target: shell
EOF
# over-threshold, unreachable host
cat > "$T/clone/build-queue/PRD-claimrec-ac9-unreachable.md" <<'EOF'
# PRD: claimrec-ac9-unreachable
- Status: building
- build_target: shell
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
BR="$(git -C "$T/clone" symbolic-ref --short HEAD)"
git -C "$T/clone" push -q origin "$BR"

LIVE_PRD="$T/clone/build-queue/PRD-claimrec-ac9-live.md"
ts=$(now_iso)
write_claim "$LIVE_PRD" building "$(hostname) $ts pid=$$ boot=$(current_boot_id)"

DEAD_PRD="$T/clone/build-queue/PRD-claimrec-ac9-deadpid.md"
DEAD_PID=999977
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID - 1)); done
write_claim "$DEAD_PRD" building "$(hostname) $ts pid=$DEAD_PID boot=$(current_boot_id)"

UNREACH_PRD="$T/clone/build-queue/PRD-claimrec-ac9-unreachable.md"
old4h=$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)
write_claim "$UNREACH_PRD" building "ryzen7 $old4h"

git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: ac9 fixtures"
git -C "$T/clone" push -q origin "$BR"

bulk=$(LANE_CLAIM_REACHABLE_OVERRIDE="ryzen7=no" "$LC" claims --prd-dir "$T/clone")
expect "bulk --json is valid JSON" "echo \"\$bulk\" | jq -e . >/dev/null"

live_state=$(echo "$bulk" | jq -r '.claims[] | select(.prd | endswith("ac9-live.md")) | .state')
dead_state=$(echo "$bulk" | jq -r '.claims[] | select(.prd | endswith("ac9-deadpid.md")) | .state')
dead_cause=$(echo "$bulk" | jq -r '.claims[] | select(.prd | endswith("ac9-deadpid.md")) | .cause')
unreach_state=$(echo "$bulk" | jq -r '.claims[] | select(.prd | endswith("ac9-unreachable.md")) | .state')

expect "live claim reads state=live" "[ '$live_state' = live ]"
expect "dead-pid claim reads state=stale" "[ '$dead_state' = stale ]"
expect "dead-pid claim's cause is dead-pid" "[ '$dead_cause' = dead-pid ]"
expect "unreachable-host claim reads state=unknown (distinct from the other two)" "[ '$unreach_state' = unknown ]"
expect "all three states are pairwise distinct" \
  "[ '$live_state' != '$dead_state' ] && [ '$dead_state' != '$unreach_state' ] && [ '$live_state' != '$unreach_state' ]"

exit $fail
