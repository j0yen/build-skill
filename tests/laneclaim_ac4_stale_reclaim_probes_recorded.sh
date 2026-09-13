#!/usr/bin/env bash
# laneclaim_ac4_stale_reclaim_probes_recorded.sh — PRD-build-lane-claim-integrity AC4.
#
# Given a claim older than threshold with no commit and no liveness
# signal (fixture lane, dead), when the tick claims it, then it is
# reclaimed and the journal line (the reclaim-receipt) records both
# probes with their timestamps.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac4: $LC not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/laneclaim-ac4.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
cat > "$T/clone/build-queue/PRD-deadclaim.md" <<'EOF'
# PRD: deadclaim
- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$T/clone" push -q origin master 2>/dev/null || git -C "$T/clone" push -q origin main 2>/dev/null
BR=$(git -C "$T/clone" symbolic-ref --short HEAD)
DC_PRD="$T/clone/build-queue/PRD-deadclaim.md"

source "$LC"
old=$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)
write_claim "$DC_PRD" building "carbon $old"
git -C "$T/clone" add -A
GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" \
  git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: deadclaim lane=carbon (fixture)"
git -C "$T/clone" push -q origin "$BR"

st=$(LANE_CLAIM_REACHABLE_OVERRIDE="carbon=yes" "$LC" status "$DC_PRD" --json)
expect "genuinely dead claim reads state=stale, stale=true" \
  "echo '$st' | jq -e '.state == \"stale\" and .stale == true' >/dev/null 2>&1"

out=$(LANE_CLAIM_REACHABLE_OVERRIDE="carbon=yes" "$LC" claim "$DC_PRD" redbaron)
expect "reclaim produces a reclaim-receipt line" "echo '$out' | grep -q '^reclaim-receipt: prev_lane=carbon'"
expect "reclaim receipt records the commit probe" "echo '$out' | grep -q 'commit=no'"
expect "reclaim receipt records the iter_log probe" "echo '$out' | grep -q 'iter_log=no'"
expect "reclaim receipt records the reachability probe" "echo '$out' | grep -q 'reachable=yes'"
expect "reclaim actually lands: new lane is redbaron" "echo '$out' | grep -q '^claimed: deadclaim lane=redbaron'"

exit $fail
