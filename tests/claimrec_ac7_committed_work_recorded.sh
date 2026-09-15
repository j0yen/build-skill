#!/usr/bin/env bash
# claimrec_ac7_committed_work_recorded.sh — PRD-build-stale-claim-auto-
# recovery AC7.
#
# Given a stranded PRD whose build_into repo holds a commit attributable
# to the dead step, When it is reclaimed, Then the iteration log records
# that commit's sha before the claim is released.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac7: lane-claim.sh not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claimrec-ac7.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
WORK_REPO="$T/work-repo"
git init -q "$WORK_REPO"
git -C "$WORK_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

cat > "$T/clone/build-queue/PRD-claimrec-ac7.md" <<EOF
# PRD: claimrec-ac7

- Status: building
- build_target: shell
- build_into: $WORK_REPO
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
BR="$(git -C "$T/clone" symbolic-ref --short HEAD)"
git -C "$T/clone" push -q origin "$BR"
PRD="$T/clone/build-queue/PRD-claimrec-ac7.md"

source "$LC"
DEAD_PID=999979
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID - 1)); done
ts=$(now_iso)
write_claim "$PRD" building "$(hostname) $ts pid=$DEAD_PID boot=$(current_boot_id)"
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: claimrec-ac7 (fixture, dead pid)"
git -C "$T/clone" push -q origin "$BR"

sleep 1  # ensure the work commit's timestamp strictly follows ts (git log --since boundary)
git -C "$WORK_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty \
  -m "landed a step (PRD-claimrec-ac7 requirement 1)"
work_sha="$(git -C "$WORK_REPO" rev-parse --short HEAD)"

out=$(JOURNAL_DIR="$T" "$LC" reclaim "$PRD")
expect "reclaim succeeds" "grep -q '^reclaimed: claimrec-ac7 cause=dead-pid status_reset=yes\$' <<<\"\$out\""
expect "iter_log records the committed-work sha" "grep -q \"iter_log:.*sha=$work_sha\" '$PRD'"
expect "Lane: line still removed (release still happened)" "! grep -q '^- Lane:' '$PRD'"

exit $fail
