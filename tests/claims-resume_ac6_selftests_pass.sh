#!/usr/bin/env bash
# claims-resume_ac6_selftests_pass.sh — PRD-build-claims-resume-not-count
# AC6.
#
# Given the selftests (lane-claim-selftest.sh, lane-predicate-selftest.sh —
# both extended with the own-claim-continuation and coordinator-liveness
# cases this PRD adds), when run, then they exit 0 with one line per
# assertion (no bare failures slipping through the "ALL ... PASSED"
# banner).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC_SELFTEST="$HERE/../scripts/lane-claim-selftest.sh"
LP_SELFTEST="$HERE/../scripts/lane-predicate-selftest.sh"
[ -x "$LC_SELFTEST" ] && [ -x "$LP_SELFTEST" ] || { echo "ac6: selftest scripts not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

for st in "$LC_SELFTEST" "$LP_SELFTEST"; do
  out=$(bash "$st" 2>&1); rc=$?
  name=$(basename "$st")
  expect "$name exits 0"                 "[ $rc -eq 0 ]"
  expect "$name reports an ALL-pass banner" "grep -qE '^ALL (SELFTESTS PASSED|PASS)\$' <<<\"\$out\""
  # No bare "FAIL" line should have slipped through even if the banner
  # printed (it wouldn't, since each script does `exit 1` on the first
  # FAIL — this is belt-and-suspenders against a future refactor that
  # forgets to propagate one).
  expect "$name has zero FAIL lines"     "! grep -q '^FAIL' <<<\"\$out\""
done

exit $fail
