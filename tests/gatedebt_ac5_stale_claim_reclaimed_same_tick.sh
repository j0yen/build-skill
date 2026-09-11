#!/usr/bin/env bash
# gatedebt_ac5_stale_claim_reclaimed_same_tick.sh — PRD-build-gate-debt-
# auto-prd AC5.
#
# Given a claim older than the stale threshold with no commit since, When
# manifest-invariants.sh's lane predicate runs, Then the claim is released
# and `claim  reclaimed` is journaled in the same tick as the `stale-claim`
# alarm (never merely alarmed — the 2026-09-11 mcphost-schedules incident
# this PRD is fixing: a stale-claim alarm fired at 05:43Z and nothing
# reclaimed it).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MI="$HERE/../scripts/manifest-invariants.sh"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$MI" ] || { echo "ac5: $MI not executable" >&2; exit 2; }
[ -x "$LC" ] || { echo "ac5: $LC not executable" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gatedebt-ac5.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# Scratch git repo standing in for the shared PRDs clone (never touches the
# real ~/Documents/PRDs), same shape as lane-claim-selftest.sh.
git init -q --bare "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$ROOT/clone"
mkdir -p "$ROOT/clone/build-queue" "$ROOT/clone/built-prds" "$ROOT/clone/parked"
cat > "$ROOT/clone/build-queue/PRD-gatedebt-fixture.md" <<'EOF'
# PRD: gatedebt-fixture

- Status: building
- build_target: shell
- build_into: /tmp/gatedebt-fixture-target
- build_priority: high
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m init
BR="$(git -C "$ROOT/clone" symbolic-ref --short HEAD)"
git -C "$ROOT/clone" push -q origin "$BR"

PRD="$ROOT/clone/build-queue/PRD-gatedebt-fixture.md"

# Write a stale claim directly (age well past the 3h threshold, no pid/boot
# trailer — the age-only rule applies regardless of hostname).
STALE_TS="$(date -u -d '5 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
source "$LC"
write_claim "$PRD" building "otherlane $STALE_TS"
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: gatedebt-fixture lane=otherlane"
git -C "$ROOT/clone" push -q origin "$BR"

STATE="$ROOT/state"
mkdir -p "$STATE/intent"
python3 -c "
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump({'prds': {'gatedebt-fixture': {
  'slug': 'gatedebt-fixture', 'status': 'building', 'blockers': [], 'iter_log': [],
  'last_action': now, 'path': '$PRD'
}}}, open('$STATE/manifest.json', 'w'))
"

export BUILD_STATE_DIR="$STATE"
export BUILD_MANIFEST="$STATE/manifest.json"
export LOCK="$STATE/tick.lock"
export JOURNAL="$ROOT/journal.md"
export LANE_CLAIM="$LC"
: > "$JOURNAL"

out="$("$MI" --prd-dir "$ROOT/clone" --format json)"; rc=$?
expect "manifest-invariants exits 0" "[ $rc -eq 0 ]"
expect "reports 1 alarmed" "grep -Eq '\"alarmed\":[[:space:]]*1' <<<\"\$out\""

expect "journal has stale-claim alarm line" \
  "grep -q 'gatedebt-fixture.*alarm.*claim is stale.*class=stale-claim' '$JOURNAL'"
expect "journal has claim reclaimed line in the SAME run" \
  "grep -q 'gatedebt-fixture  claim  reclaimed  (prd=gatedebt-fixture' '$JOURNAL'"

# The reclaim must be a real release: origin's Lane: line is gone.
git -C "$ROOT/clone" pull -q --rebase
expect "Lane: line removed from the PRD (real release, not just journaled)" \
  "! grep -q '^- Lane:' '$PRD'"
expect "origin (not just local clone) reflects the release" \
  "! git --git-dir='$ROOT/origin.git' show '$BR:build-queue/PRD-gatedebt-fixture.md' | grep -q '^- Lane:'"

exit $fail
