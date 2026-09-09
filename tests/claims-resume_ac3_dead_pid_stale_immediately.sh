#!/usr/bin/env bash
# claims-resume_ac3_dead_pid_stale_immediately.sh — PRD-build-claims-
# resume-not-count AC3.
#
# Given a claim whose recorded PID does not exist, when lane-claim.sh
# evaluates it, then it is stale at age 0 (not after the usual 3h window)
# and this lane resumes it.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac3: lane-claim.sh not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/claims-resume-ac3.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
cat > "$T/clone/build-queue/PRD-deadpid.md" <<'EOF'
# PRD: deadpid
- Status: queued
- build_target: shell
- build_into: /tmp/claims-resume-ac3-target
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$T/clone" push -q origin master 2>/dev/null || git -C "$T/clone" push -q origin main 2>/dev/null

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

PRD="$T/clone/build-queue/PRD-deadpid.md"

# Fixture the claim directly (rather than through cmd_claim, so the
# recorded PID is one we control): same lane as this host, a PID
# guaranteed not to be running, current boot id, timestamp NOW (age 0).
source "$LC"
DEAD_PID=999999
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID - 1)); done
ts=$(now_iso)
write_claim "$PRD" building "$(hostname) $ts pid=$DEAD_PID boot=$(current_boot_id)"
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: deadpid lane=$(hostname) (fixture)"
git -C "$T/clone" push -q origin "$(git -C "$T/clone" symbolic-ref --short HEAD)"

out=$("$LC" status "$PRD")
expect "status reports stale=yes despite age~0" "grep -q 'stale=yes' <<<\"\$out\""
age_val=$(sed -E 's/.*age=([0-9]+)s.*/\1/' <<<"$out")
expect "age is immediate (<10s), not the 3h window" "[ \"$age_val\" -lt 10 ]"

out=$("$LC" target-busy /tmp/claims-resume-ac3-target --lane "$(hostname)" --prd-dir "$T/clone")
expect "the dead-pid claim doesn't occupy this lane's sub-cap" "[ \"\$out\" = free ]"

exit $fail
