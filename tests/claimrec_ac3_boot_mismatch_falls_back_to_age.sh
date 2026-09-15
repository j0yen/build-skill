#!/usr/bin/env bash
# claimrec_ac3_boot_mismatch_falls_back_to_age.sh — PRD-build-stale-claim-
# auto-recovery AC3.
#
# Given a fixture PRD whose claim records a different boot= id than the
# current boot (a claim from another host — boot ids are only ever
# comparable host-local, so a foreign-host claim's boot id is always
# "different" from this host's), When the reclaim sweep runs, Then the pid
# check is not trusted and the age threshold decides: fresh -> not stale
# (refused), past-threshold with no other liveness signal -> reclaimed via
# cause=stale-age, never cause=dead-pid (the pid trailer is never treated
# as confirming death for a claim this host cannot liveness-probe).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac3: lane-claim.sh not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claimrec-ac3.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
BR=""
source "$LC"

# -- part 1: fresh foreign-host claim (age < threshold) -> refused --------
cat > "$T/clone/build-queue/PRD-claimrec-ac3a.md" <<'EOF'
# PRD: claimrec-ac3a

- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m add-ac3a
BR="$(git -C "$T/clone" symbolic-ref --short HEAD)"
git -C "$T/clone" push -q origin "$BR"
PRD_A="$T/clone/build-queue/PRD-claimrec-ac3a.md"

ts=$(now_iso)
write_claim "$PRD_A" building "some-other-fleet-host $ts pid=$$ boot=$(current_boot_id)"
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: claimrec-ac3a (fixture, foreign host, fresh)"
git -C "$T/clone" push -q origin "$BR"

set +e
out=$(LANE_CLAIM_REACHABLE_OVERRIDE="some-other-fleet-host=yes" JOURNAL_DIR="$T" "$LC" reclaim "$PRD_A" 2>&1); rc=$?
set -e
expect "fresh foreign-host claim refused (age decides, not yet stale)" "[ $rc -eq 1 ]"
expect "Lane: line untouched" "grep -q '^- Lane:' '$PRD_A'"

# -- part 2: past-threshold foreign-host claim, no other signal -> stale-age, never dead-pid
cat > "$T/clone/build-queue/PRD-claimrec-ac3b.md" <<'EOF'
# PRD: claimrec-ac3b

- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m add-ac3b
git -C "$T/clone" push -q origin "$BR"
PRD_B="$T/clone/build-queue/PRD-claimrec-ac3b.md"

old4h=$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)
write_claim "$PRD_B" building "some-other-fleet-host $old4h pid=999988 boot=deadbeef-fake-boot-id"
git -C "$T/clone" add -A
GIT_AUTHOR_DATE="$old4h" GIT_COMMITTER_DATE="$old4h" \
  git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: claimrec-ac3b (fixture, foreign host, old)"
git -C "$T/clone" push -q origin "$BR"

out=$(LANE_CLAIM_REACHABLE_OVERRIDE="some-other-fleet-host=yes" JOURNAL_DIR="$T" "$LC" reclaim "$PRD_B")
expect "past-threshold foreign-host claim reclaimed via cause=stale-age" \
  "grep -q '^reclaimed: claimrec-ac3b cause=stale-age status_reset=yes\$' <<<\"\$out\""
expect "never mis-attributed as cause=dead-pid (pid check not trusted cross-host)" \
  "! grep -q 'cause=dead-pid' <<<\"\$out\""

exit $fail
