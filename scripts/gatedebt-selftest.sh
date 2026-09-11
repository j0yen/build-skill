#!/usr/bin/env bash
# gatedebt-selftest.sh — runs the `gatedebt` fixture set (PRD-build-gate-
# debt-auto-prd requirement 7 / AC7) and names each case by file, so a
# human or a tick reading this script's output can tell which acceptance
# criterion is covered without opening every file under tests/.
#
# Covers: attribution splits in-scope from inherited on a fake diff (AC1);
# two identical blocked gates draft exactly one debt PRD with countable ACs
# (AC2); the blocked PRD is parked (AC3) and released (AC4); a stale claim
# is reclaimed in the same tick that alarms it (AC5); the resurrection
# check journals findings after a fake union-resolve merge, tagged
# origin=union-resolve (AC6).
#
# Usage: gatedebt-selftest.sh
# Exit: 0 iff every gatedebt_ac*.sh case exits 0; 1 otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$HERE/../tests"

fail=0
count=0
for f in "$TESTS_DIR"/gatedebt_ac*.sh; do
  [ -f "$f" ] || continue
  count=$((count + 1))
  name="$(basename "$f" .sh)"
  if bash "$f" >"/tmp/gatedebt-selftest.$name.out" 2>&1; then
    echo "ok  $name"
  else
    echo "FAIL $name (see /tmp/gatedebt-selftest.$name.out)"
    fail=1
  fi
done

if [ "$count" -eq 0 ]; then
  echo "gatedebt-selftest: no tests/gatedebt_ac*.sh cases found" >&2
  exit 1
fi

echo "----"
echo "gatedebt-selftest: $count case(s), $([ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "FAILURES ABOVE")"
exit "$fail"
