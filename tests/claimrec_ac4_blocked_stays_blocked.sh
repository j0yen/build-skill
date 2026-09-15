#!/usr/bin/env bash
# claimrec_ac4_blocked_stays_blocked.sh — PRD-build-stale-claim-auto-
# recovery AC4.
#
# Given a fixture PRD with Status: blocked and a dead-pid claim, When the
# sweep runs, Then the claim is released and the status stays blocked.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac4: lane-claim.sh not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claimrec-ac4.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
cat > "$T/clone/build-queue/PRD-claimrec-ac4.md" <<'EOF'
# PRD: claimrec-ac4

- Status: blocked
- build_target: shell
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
BR="$(git -C "$T/clone" symbolic-ref --short HEAD)"
git -C "$T/clone" push -q origin "$BR"
PRD="$T/clone/build-queue/PRD-claimrec-ac4.md"

source "$LC"
DEAD_PID=999987
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID - 1)); done
ts=$(now_iso)
write_claim "$PRD" blocked "$(hostname) $ts pid=$DEAD_PID boot=$(current_boot_id)"
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: claimrec-ac4 (fixture, dead pid + blocked)"
git -C "$T/clone" push -q origin "$BR"

out=$(JOURNAL_DIR="$T" "$LC" reclaim "$PRD")
expect "reclaim reports status_reset=no" \
  "grep -q '^reclaimed: claimrec-ac4 cause=dead-pid status_reset=no\$' <<<\"\$out\""
expect "Status stays blocked" "grep -q '^- Status: blocked' '$PRD'"
expect "Lane: line removed" "! grep -q '^- Lane:' '$PRD'"
expect "journal records status_reset=no" "grep -q 'claimrec-ac4.*status_reset=no' '$T'/*.md"

exit $fail
