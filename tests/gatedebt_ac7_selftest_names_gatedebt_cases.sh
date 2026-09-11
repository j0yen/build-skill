#!/usr/bin/env bash
# gatedebt_ac7_selftest_names_gatedebt_cases.sh — PRD-build-gate-debt-
# auto-prd AC7.
#
# Given the selftest fixture set, When gatedebt-selftest.sh runs, Then it
# exits 0 and names the gatedebt cases (AC1-6, by file basename) so a
# human or a tick reading the output can tell which acceptance criterion
# each case covers without opening every file under tests/.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GS="$HERE/../scripts/gatedebt-selftest.sh"
[ -x "$GS" ] || { echo "ac7: $GS not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

out="$("$GS" 2>&1)"; rc=$?
expect "gatedebt-selftest.sh exits 0" "[ $rc -eq 0 ]"
for n in 1 2 3 4 5 6; do
  expect "names gatedebt_ac${n} case" "grep -q 'gatedebt_ac${n}_' <<<\"\$out\""
done

exit $fail
