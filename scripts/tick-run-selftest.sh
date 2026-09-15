#!/usr/bin/env bash
# tick-run-selftest.sh — runs the `ticklock` fixture set
# (PRD-build-tick-lock-held, test_prefix `ticklock`) and names each case
# by file, mirroring scripts/gatephase-selftest.sh's convention (same
# reentrancy hazard note applies: none of the ticklock_ac*.sh cases invoke
# this aggregator, so there is nothing to guard against recursing into
# here, but the guard is kept for consistency with sibling aggregators and
# as a cheap tripwire if a future case ever does).
#
# Usage: tick-run-selftest.sh
# Env: TICKLOCK_TESTS_DIR overrides the fixture directory (default
#      <repo>/tests).
# Exit: 0 iff every ticklock_ac*.sh case exits 0; 1 otherwise; 3 if called
#      reentrantly.
set -uo pipefail

if [ -n "${TICKLOCK_SELFTEST_RUNNING:-}" ]; then
  echo "tick-run-selftest: refusing reentrant invocation" >&2
  exit 3
fi
export TICKLOCK_SELFTEST_RUNNING=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${TICKLOCK_TESTS_DIR:-$HERE/../tests}"

fail=0
count=0
for f in "$TESTS_DIR"/ticklock_ac*.sh; do
  [ -f "$f" ] || continue
  count=$((count + 1))
  name="$(basename "$f" .sh)"
  if bash "$f" >"/tmp/tick-run-selftest.$name.out" 2>&1; then
    echo "ok  $name"
  else
    echo "FAIL $name (see /tmp/tick-run-selftest.$name.out)"
    fail=1
  fi
done

if [ "$count" -eq 0 ]; then
  echo "tick-run-selftest: no tests/ticklock_ac*.sh cases found" >&2
  exit 1
fi

echo "----"
echo "tick-run-selftest: $count case(s), $([ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "FAILURES ABOVE")"
exit "$fail"
