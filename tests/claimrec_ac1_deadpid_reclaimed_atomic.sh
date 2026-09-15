#!/usr/bin/env bash
# claimrec_ac1_deadpid_reclaimed_atomic.sh — PRD-build-stale-claim-auto-
# recovery AC1.
#
# Given a fixture PRD claimed by a pid that is not running on the current
# boot, When the reclaim sweep runs, Then the claim is released, Status is
# reset to queued in the file and the manifest, both land in one commit,
# and `claim  reclaimed  (... cause=dead-pid status_reset=yes probes: ...)`
# is journaled.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
MANIFEST_SET="$HERE/../scripts/manifest-set.sh"
[ -x "$LC" ] || { echo "ac1: lane-claim.sh not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claimrec-ac1.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue" "$T/state"
cat > "$T/clone/build-queue/PRD-claimrec-ac1.md" <<'EOF'
# PRD: claimrec-ac1

- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
BR="$(git -C "$T/clone" symbolic-ref --short HEAD)"
git -C "$T/clone" push -q origin "$BR"
PRD="$T/clone/build-queue/PRD-claimrec-ac1.md"

source "$LC"
DEAD_PID=999989
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID - 1)); done
ts=$(now_iso)
write_claim "$PRD" building "$(hostname) $ts pid=$DEAD_PID boot=$(current_boot_id)"
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: claimrec-ac1 (fixture, dead pid)"
git -C "$T/clone" push -q origin "$BR"
before_head="$(git -C "$T/clone" rev-parse HEAD)"

echo '{"prds": {"claimrec-ac1": {"status": "building"}}}' > "$T/state/manifest.json"

out=$(JOURNAL_DIR="$T" BUILD_STATE_DIR="$T/state" BUILD_MANIFEST="$T/state/manifest.json" MANIFEST_SET_SH="$MANIFEST_SET" "$LC" reclaim "$PRD")
expect "reclaim reports success with cause=dead-pid status_reset=yes" \
  "grep -q '^reclaimed: claimrec-ac1 cause=dead-pid status_reset=yes\$' <<<\"\$out\""

after_head="$(git -C "$T/clone" rev-parse HEAD)"
expect "exactly one new commit landed (claim release + status reset together)" \
  "[ \"\$(git -C '$T/clone' rev-list --count $before_head..$after_head)\" -eq 1 ]"
expect "Status reset to queued in the PRD file" "grep -q '^- Status: queued' '$PRD'"
expect "Lane: line removed" "! grep -q '^- Lane:' '$PRD'"

manifest_status="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['claimrec-ac1']['status'])")"
expect "manifest entry set to queued" "[ '$manifest_status' = queued ]"

jline="$(grep 'claim  reclaimed' "$T"/*.md)"
expect "journal names the prd" "grep -q 'prd=claimrec-ac1' <<<\"\$jline\""
expect "journal names cause=dead-pid" "grep -q 'cause=dead-pid' <<<\"\$jline\""
expect "journal names status_reset=yes" "grep -q 'status_reset=yes' <<<\"\$jline\""
expect "journal carries probes:" "grep -q 'probes: ' <<<\"\$jline\""

exit $fail
