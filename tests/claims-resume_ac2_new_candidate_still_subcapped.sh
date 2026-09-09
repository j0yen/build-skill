#!/usr/bin/env bash
# claims-resume_ac2_new_candidate_still_subcapped.sh — PRD-build-claims-
# resume-not-count AC2.
#
# Given the same three continuations (AC1) and a fourth queued PRD on the
# repo, when selection runs, then the fourth is skipped sub-cap-blocked
# and the three are still admitted (own-claim exemption never turns into
# an unbounded free-for-all — it exempts only the claims that already
# exist, not new ones).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
LP="$HERE/../scripts/lane-predicate.sh"
[ -x "$LC" ] && [ -x "$LP" ] || { echo "ac2: helper scripts not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/claims-resume-ac2.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
for n in a b c d; do
cat > "$T/clone/build-queue/PRD-own-$n.md" <<EOF
# PRD: own-$n
- Status: queued
- build_target: shell
- build_into: /tmp/claims-resume-ac2-target
EOF
done
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$T/clone" push -q origin master 2>/dev/null || git -C "$T/clone" push -q origin main 2>/dev/null

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

A="$T/clone/build-queue/PRD-own-a.md"
B="$T/clone/build-queue/PRD-own-b.md"
C="$T/clone/build-queue/PRD-own-c.md"
D="$T/clone/build-queue/PRD-own-d.md"

"$LC" claim "$A" redbaron >/dev/null
"$LC" claim "$B" redbaron >/dev/null
"$LC" claim "$C" redbaron >/dev/null

for f in "$A" "$B" "$C"; do
  out=$("$LP" select "$f" redbaron "$T/clone"); rc=$?
  expect "continuation $f still admitted" "[ $rc -eq 0 ]"
done

out=$("$LP" select "$D" redbaron "$T/clone"); rc=$?
expect "never-claimed 4th PRD is skipped this tick"  "[ $rc -eq 1 ]"
expect "the skip names the sub-cap, not generic busy" "grep -q '^skip: sub-cap:' <<<\"\$out\""

exit $fail
