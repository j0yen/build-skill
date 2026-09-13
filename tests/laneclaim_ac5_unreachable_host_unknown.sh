#!/usr/bin/env bash
# laneclaim_ac5_unreachable_host_unknown.sh — PRD-build-lane-claim-integrity AC5.
#
# Given an unreachable claiming host, when stale detection runs, then
# the claim is marked unknown and NOT reclaimed (default per the PRD's
# open question: unreachable => unknown => no reclaim).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac5: $LC not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/laneclaim-ac5.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
cat > "$T/clone/build-queue/PRD-unreachable.md" <<'EOF'
# PRD: unreachable
- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$T/clone" push -q origin master 2>/dev/null || git -C "$T/clone" push -q origin main 2>/dev/null
BR=$(git -C "$T/clone" symbolic-ref --short HEAD)
UR_PRD="$T/clone/build-queue/PRD-unreachable.md"

source "$LC"
old=$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)
write_claim "$UR_PRD" building "ryzen7 $old"
git -C "$T/clone" add -A
GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" \
  git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: unreachable lane=ryzen7 (fixture, ryzen7 off)"
git -C "$T/clone" push -q origin "$BR"

st=$(LANE_CLAIM_REACHABLE_OVERRIDE="ryzen7=no" "$LC" status "$UR_PRD" --json)
expect "unreachable host reads state=unknown, stale=false" \
  "echo '$st' | jq -e '.state == \"unknown\" and .stale == false' >/dev/null 2>&1"

set +e
out=$(LANE_CLAIM_REACHABLE_OVERRIDE="ryzen7=no" "$LC" claim "$UR_PRD" redbaron 2>&1); rc=$?
set -e
expect "unknown-state claim is held, never reclaimed (exit 2)" "[ $rc -eq 2 ]"
expect "held message names state=unknown" "echo '$out' | grep -q 'state=unknown'"

exit $fail
