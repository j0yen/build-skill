#!/usr/bin/env bash
# claimrec_ac5_write_failure_leaves_state_unchanged.sh — PRD-build-stale-
# claim-auto-recovery AC5.
#
# Given a reclaim that can release the claim but cannot write the status
# (simulated write failure), When it runs, Then it exits non-zero,
# journals the failure, and leaves the claim, the file, and the manifest
# unchanged.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac5: lane-claim.sh not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claimrec-ac5.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue" "$T/state"
cat > "$T/clone/build-queue/PRD-claimrec-ac5.md" <<'EOF'
# PRD: claimrec-ac5

- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
BR="$(git -C "$T/clone" symbolic-ref --short HEAD)"
git -C "$T/clone" push -q origin "$BR"
PRD="$T/clone/build-queue/PRD-claimrec-ac5.md"

source "$LC"
DEAD_PID=999986
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID - 1)); done
ts=$(now_iso)
write_claim "$PRD" building "$(hostname) $ts pid=$DEAD_PID boot=$(current_boot_id)"
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: claimrec-ac5 (fixture, dead pid)"
git -C "$T/clone" push -q origin "$BR"
before_head="$(git -C "$T/clone" rev-parse HEAD)"

echo '{"prds": {"claimrec-ac5": {"status": "building"}}}' > "$T/state/manifest.json"
manifest_before="$(cat "$T/state/manifest.json")"

set +e
out=$(LANE_CLAIM_RECLAIM_FAIL_WRITE=1 JOURNAL_DIR="$T" BUILD_STATE_DIR="$T/state" BUILD_MANIFEST="$T/state/manifest.json" "$LC" reclaim "$PRD" 2>&1); rc=$?
set -e
expect "exits non-zero" "[ $rc -ne 0 ]"

after_head="$(git -C "$T/clone" rev-parse HEAD)"
expect "no commit landed" "[ '$before_head' = '$after_head' ]"
expect "Lane: line still present" "grep -q '^- Lane:' '$PRD'"
expect "Status unchanged" "grep -q '^- Status: building' '$PRD'"
expect "manifest byte-for-byte unchanged" "[ \"\$(cat '$T/state/manifest.json')\" = '$manifest_before' ]"
expect "failure journaled" "grep -q 'claimrec-ac5.*claim  reclaim-failed' '$T'/*.md"

exit $fail
