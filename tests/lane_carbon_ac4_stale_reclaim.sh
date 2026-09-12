#!/usr/bin/env bash
# lane_carbon_ac4_stale_reclaim.sh — PRD-build-second-lane-carbon AC4.
#
# Given a claim 3+ hours old with no subsequent commits for that PRD, when
# a lane reclaims it, then the reclaim receipt (age, host probe) is
# printed for the journal and the build proceeds (exit 0).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac4: $LC not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/lane-carbon-ac4.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"

# A claim from 4 hours ago — older than the 3h stale threshold. The init
# commit itself is backdated to that same instant (GIT_AUTHOR/COMMITTER_DATE)
# — PRD-build-lane-claim-integrity's evidence bar checks for a commit AFTER
# the claim, so an un-backdated "now" commit that merely happens to carry a
# stale-looking Lane: value would itself look like post-claim activity and
# read as long-running rather than genuinely stale.
stale_ts=$(date -u -d '-4 hours' +%Y-%m-%dT%H:%M:%SZ)
cat > "$T/clone/build-queue/PRD-sleepy.md" <<EOF
# PRD: sleepy
- Status: building
- build_target: shell
- Lane: carbon $stale_ts
EOF
git -C "$T/clone" add -A
GIT_AUTHOR_DATE="$stale_ts" GIT_COMMITTER_DATE="$stale_ts" \
  git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$T/clone" push -q origin master 2>/dev/null || git -C "$T/clone" push -q origin main 2>/dev/null

PRD="$T/clone/build-queue/PRD-sleepy.md"
# Never read the real ~/brain/journal/build (hermetic — a real journal
# mentioning the "sleepy" slug by coincidence would false-positive the
# journal-activity liveness probe below).
export JOURNAL_DIR="$T/journal"
mkdir -p "$JOURNAL_DIR"
# "carbon" is a real fleet hostname but has no network presence in this
# scratch/CI environment — pin it reachable so the evidence-bar's AC5
# unreachable-host check doesn't read this as unknown and skip the reclaim
# this test is actually about.
export LANE_CLAIM_REACHABLE_OVERRIDE="carbon=yes"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

status_out=$("$LC" status "$PRD")
expect "status reports the claim as stale before reclaim" "grep -q 'stale=yes' <<<\"\$status_out\""

out=$("$LC" claim "$PRD" RedBaron); rc=$?
expect "reclaim succeeds (exit 0)"                         "[ $rc -eq 0 ]"
expect "a reclaim receipt is printed (age + probes)"       "grep -q '^reclaim-receipt: prev_lane=carbon .*age=.*probes: ' <<<\"\$out\""
expect "the new claim lands under the reclaiming lane"     "grep -q '^- Lane: RedBaron' \"\$PRD\""

exit $fail
