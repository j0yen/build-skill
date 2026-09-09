#!/usr/bin/env bash
# claims-resume_ac1_continuation_admitted_at_subcap.sh — PRD-build-claims-
# resume-not-count AC1.
#
# Given three PRDs claimed by this lane on one repo and the sub-cap at 3,
# when selection runs, then all three are admitted as continuations
# ("resume=own-claim" / "resume: own claim ..." — the 06:23Z OOM shape:
# a dead coordinator's own claims must never block one another).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
LP="$HERE/../scripts/lane-predicate.sh"
[ -x "$LC" ] && [ -x "$LP" ] || { echo "ac1: helper scripts not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/claims-resume-ac1.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
for n in a b c; do
cat > "$T/clone/build-queue/PRD-own-$n.md" <<EOF
# PRD: own-$n
- Status: queued
- build_target: shell
- build_into: /tmp/claims-resume-ac1-target
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

# This lane claims all three — sub-cap (3) is now fully occupied by its
# OWN claims, exactly as the dead 06:23Z coordinator left six mcphost PRDs.
"$LC" claim "$A" redbaron >/dev/null
"$LC" claim "$B" redbaron >/dev/null
"$LC" claim "$C" redbaron >/dev/null

for f in "$A" "$B" "$C"; do
  out=$("$LP" select "$f" redbaron "$T/clone"); rc=$?
  expect "select($f) exits 0 (admitted)"       "[ $rc -eq 0 ]"
  expect "select($f) reports resume=own-claim" "grep -q 'resume=own-claim\$' <<<\"\$out\""
done

exit $fail
