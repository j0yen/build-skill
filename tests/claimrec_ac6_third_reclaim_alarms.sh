#!/usr/bin/env bash
# claimrec_ac6_third_reclaim_alarms.sh — PRD-build-stale-claim-auto-
# recovery AC6.
#
# Given a fixture PRD reclaimed three times within 24h, When the third
# reclaim runs, Then an alarm line is journaled naming the slug and the
# count.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac6: lane-claim.sh not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claimrec-ac6.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
cat > "$T/clone/build-queue/PRD-claimrec-ac6.md" <<'EOF'
# PRD: claimrec-ac6

- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
BR="$(git -C "$T/clone" symbolic-ref --short HEAD)"
git -C "$T/clone" push -q origin "$BR"
PRD="$T/clone/build-queue/PRD-claimrec-ac6.md"

source "$LC"
for i in 1 2 3; do
  DEAD_PID=$((999985 - i))
  while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID - 1)); done
  ts=$(now_iso)
  write_claim "$PRD" building "$(hostname) $ts pid=$DEAD_PID boot=$(current_boot_id)"
  git -C "$T/clone" add -A
  git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: claimrec-ac6 re-claim #$i (fixture, dead pid)"
  git -C "$T/clone" push -q origin "$BR"
  out=$(JOURNAL_DIR="$T" "$LC" reclaim "$PRD")
  expect "reclaim #$i succeeds" "grep -q '^reclaimed: claimrec-ac6 ' <<<\"\$out\""
done

expect "3rd reclaim journals an alarm naming the slug and count" \
  "grep -q 'claimrec-ac6  claim  reclaim-alarm  (count=3 window=24h)' '$T'/*.md"

exit $fail
