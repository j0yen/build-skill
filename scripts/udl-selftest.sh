#!/usr/bin/env bash
# udl-selftest.sh — runs the `udl` fixture set
# (PRD-build-tick-under-dispatch-ledger, test_prefix `udl`), mirroring
# scripts/tick-run-selftest.sh's own aggregator convention exactly (same
# reentrancy-guard note applies: no udl_ac*.sh case invokes this
# aggregator itself, so there is nothing to recurse into, but the guard is
# kept for consistency with every sibling aggregator).
#
# Usage: udl-selftest.sh
# Env: UDL_TESTS_DIR overrides the fixture directory (default <repo>/tests).
# Exit: 0 iff every udl_ac*.sh case exits 0; 1 otherwise; 3 if called
#      reentrantly.
set -uo pipefail

if [ -n "${UDL_SELFTEST_RUNNING:-}" ]; then
  echo "udl-selftest: refusing reentrant invocation" >&2
  exit 3
fi
export UDL_SELFTEST_RUNNING=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${UDL_TESTS_DIR:-$HERE/../tests}"

fail=0
count=0
for f in "$TESTS_DIR"/udl_ac*.sh; do
  [ -f "$f" ] || continue
  count=$((count + 1))
  name="$(basename "$f" .sh)"
  if bash "$f" >"/tmp/udl-selftest.$name.out" 2>&1; then
    echo "ok  $name"
  else
    echo "FAIL $name (see /tmp/udl-selftest.$name.out)"
    fail=1
  fi
done

if [ "$count" -eq 0 ]; then
  echo "udl-selftest: no tests/udl_ac*.sh cases found" >&2
  exit 1
fi

echo "----"
echo "udl-selftest: $count case(s), $([ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "FAILURES ABOVE")"
exit "$fail"
