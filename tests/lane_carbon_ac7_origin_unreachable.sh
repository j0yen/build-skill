#!/usr/bin/env bash
# lane_carbon_ac7_origin_unreachable.sh — PRD-build-second-lane-carbon AC7.
#
# Given origin unreachable from carbon, when its tick starts, then it
# builds nothing, journals the reason, and exits cleanly (exit 1 +
# "unreachable" from the reachability check the tick consults before
# assembling its candidate pool).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LP="$HERE/../scripts/lane-predicate.sh"
[ -x "$LP" ] || { echo "ac7: $LP not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/lane-carbon-ac7.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q "$T/repo" >/dev/null
git -C "$T/repo" remote add origin "/tmp/does-not-exist-$$.git"

out=$("$LP" reachable "$T/repo" 2>&1); rc=$?
expect "unreachable origin reports exit 1"   "[ $rc -eq 1 ]"
expect "unreachable origin prints the word"  "[ \"\$out\" = unreachable ]"

# A reachable origin (the real bare remote we just made valid) proves the
# check isn't unconditionally red.
git init -q --bare "$T/origin.git" >/dev/null
git -C "$T/repo" remote set-url origin "$T/origin.git"
out2=$("$LP" reachable "$T/repo"); rc2=$?
expect "reachable origin reports exit 0" "[ $rc2 -eq 0 ]"
expect "reachable origin prints the word" "[ \"\$out2\" = reachable ]"

exit $fail
