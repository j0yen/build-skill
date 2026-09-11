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
# Env: GATEDEBT_TESTS_DIR overrides the fixture directory (default
#      <repo>/tests) — used by AC7's own test to point this aggregator at
#      an isolated scratch fixture set instead of the real tests/ dir, so
#      testing "the aggregator names its cases" never has to invoke the
#      aggregator on a directory that contains AC7's own test file (see
#      the reentrancy guard below for why that would matter).
# Exit: 0 iff every gatedebt_ac*.sh case exits 0; 1 otherwise; 3 if called
#      reentrantly (see guard below).
set -uo pipefail

# Reentrancy guard (2026-09-11 postmortem): a gatedebt_ac*.sh case that
# invokes this aggregator on the real tests/ dir recurses forever, because
# the aggregator's own loop would reach that very case file and re-invoke
# the aggregator again, ad infinitum — this forked >60 processes on
# RedBaron before being caught. AC7's test now uses GATEDEBT_TESTS_DIR to
# avoid ever doing that, but this guard is the deep fix: any future case
# that accidentally calls this script on the shared tests/ dir fails fast
# with exit 3 instead of forking without bound.
if [ -n "${GATEDEBT_SELFTEST_RUNNING:-}" ]; then
  echo "gatedebt-selftest: refusing reentrant invocation — a gatedebt_ac*.sh case called this aggregator on the same tests dir it is already running from (see PRD-build-gate-debt-auto-prd AC7 postmortem)" >&2
  exit 3
fi
export GATEDEBT_SELFTEST_RUNNING=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${GATEDEBT_TESTS_DIR:-$HERE/../tests}"

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
