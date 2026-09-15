#!/usr/bin/env bash
# claimrec_ac2_live_claim_untouched.sh — PRD-build-stale-claim-auto-recovery
# AC2.
#
# Given a fixture PRD claimed by a live pid, When the sweep runs, Then
# nothing is changed and nothing is journaled for it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac2: lane-claim.sh not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claimrec-ac2.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
cat > "$T/clone/build-queue/PRD-claimrec-ac2.md" <<'EOF'
# PRD: claimrec-ac2

- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
BR="$(git -C "$T/clone" symbolic-ref --short HEAD)"
git -C "$T/clone" push -q origin "$BR"
PRD="$T/clone/build-queue/PRD-claimrec-ac2.md"

source "$LC"
ts=$(now_iso)
write_claim "$PRD" building "$(hostname) $ts pid=$$ boot=$(current_boot_id)"
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: claimrec-ac2 (fixture, live pid)"
git -C "$T/clone" push -q origin "$BR"
before_head="$(git -C "$T/clone" rev-parse HEAD)"

set +e
out=$(JOURNAL_DIR="$T" "$LC" reclaim "$PRD" 2>&1); rc=$?
set -e
expect "reclaim refuses with exit 1" "[ $rc -eq 1 ]"
expect "refusal names state=live" "grep -q '^not-stale: state=live\$' <<<\"\$out\""

after_head="$(git -C "$T/clone" rev-parse HEAD)"
expect "no commit landed" "[ '$before_head' = '$after_head' ]"
expect "Lane: line still present" "grep -q '^- Lane:' '$PRD'"
expect "Status unchanged" "grep -q '^- Status: building' '$PRD'"
expect "nothing journaled for this slug" "! grep -q 'claimrec-ac2' '$T'/*.md 2>/dev/null"

exit $fail
