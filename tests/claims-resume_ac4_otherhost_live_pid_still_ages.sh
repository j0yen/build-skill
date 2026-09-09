#!/usr/bin/env bash
# claims-resume_ac4_otherhost_live_pid_still_ages.sh — PRD-build-claims-
# resume-not-count AC4.
#
# Given a claim from another host aged 1h with a live PID recorded there
# (fixture), when this lane evaluates it, then the repo is target-busy and
# the PRD is skipped — coordinator liveness is host-local (PID namespaces
# aren't shared across the fleet), so a foreign-lane claim always keeps
# the plain 3h age rule regardless of what PID it carries (Non-goal:
# "Changing the three-hour rule for claims whose coordinator is alive on
# another host").

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
LP="$HERE/../scripts/lane-predicate.sh"
[ -x "$LC" ] && [ -x "$LP" ] || { echo "ac4: helper scripts not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/claims-resume-ac4.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
cat > "$T/clone/build-queue/PRD-otherhost.md" <<'EOF'
# PRD: otherhost
- Status: queued
- build_target: shell
- build_into: /tmp/claims-resume-ac4-target
EOF
# A second, still-queued PRD sharing the same build_into — this is the
# realistic candidate: a PRD already carrying a foreign claim never even
# reaches "select" (its own Status is "building", not "queued"), so what
# must be proven busy/skipped is a co-tenant of the same repo.
cat > "$T/clone/build-queue/PRD-otherhost-newcomer.md" <<'EOF'
# PRD: otherhost-newcomer
- Status: queued
- build_target: shell
- build_into: /tmp/claims-resume-ac4-target
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$T/clone" push -q origin master 2>/dev/null || git -C "$T/clone" push -q origin main 2>/dev/null

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

PRD="$T/clone/build-queue/PRD-otherhost.md"
NEWCOMER="$T/clone/build-queue/PRD-otherhost-newcomer.md"

# Fixture: claimed 1h ago by a lane that is definitely not this host, with
# pid=$$ (this very shell — genuinely alive right now) so a naive PID check
# would wrongly call it "alive" too — the point is we must not even TRY to
# check liveness cross-host; only the age rule applies.
source "$LC"
one_hour_ago=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
write_claim "$PRD" building "fixture-other-lane $one_hour_ago pid=$$ boot=$(current_boot_id)"
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: otherhost lane=fixture-other-lane (fixture)"
git -C "$T/clone" push -q origin "$(git -C "$T/clone" symbolic-ref --short HEAD)"

set +e
busy_out=$("$LC" target-busy /tmp/claims-resume-ac4-target --lane redbaron --prd-dir "$T/clone" 2>&1); busy_rc=$?
set -e
expect "target-busy blocks (exit 1)"        "[ $busy_rc -eq 1 ]"
expect "busy message names the foreign lane" "grep -q '^busy: otherhost fixture-other-lane' <<<\"\$busy_out\""

set +e
sel_out=$("$LP" select "$NEWCOMER" redbaron "$T/clone" 2>&1); sel_rc=$?
set -e
expect "select() skips the co-tenant PRD this tick" "[ $sel_rc -eq 1 ]"
expect "select() reports skip: busy: ..."           "grep -q '^skip: busy:' <<<\"\$sel_out\""

exit $fail
