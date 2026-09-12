#!/usr/bin/env bash
# gatephase-selftest.sh — runs the `gatephase` fixture set
# (PRD-build-gate-phase-timing, test_prefix `gatephase`) and names each
# case by file, so a human or a tick reading this script's output can tell
# which acceptance criterion is covered without opening every file under
# tests/. Mirrors scripts/gatedebt-selftest.sh exactly (same convention,
# same repo, same reentrancy hazard: a gatephase_ac*.sh case that invoked
# this aggregator on the real tests/ dir would recurse forever, since the
# aggregator's own loop would reach that very case file and re-invoke the
# aggregator again).
#
# Usage: gatephase-selftest.sh
# Env: GATEPHASE_TESTS_DIR overrides the fixture directory (default
#      <repo>/tests) — used by AC7's own test to point this aggregator at
#      an isolated scratch fixture set instead of the real tests/ dir.
# Exit: 0 iff every gatephase_ac*.sh case exits 0; 1 otherwise; 3 if called
#      reentrantly (see guard below).
set -uo pipefail

if [ -n "${GATEPHASE_SELFTEST_RUNNING:-}" ]; then
  echo "gatephase-selftest: refusing reentrant invocation — a gatephase_ac*.sh case called this aggregator on the same tests dir it is already running from" >&2
  exit 3
fi
export GATEPHASE_SELFTEST_RUNNING=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${GATEPHASE_TESTS_DIR:-$HERE/../tests}"

fail=0
count=0
for f in "$TESTS_DIR"/gatephase_ac*.sh; do
  [ -f "$f" ] || continue
  count=$((count + 1))
  name="$(basename "$f" .sh)"
  if bash "$f" >"/tmp/gatephase-selftest.$name.out" 2>&1; then
    echo "ok  $name"
  else
    echo "FAIL $name (see /tmp/gatephase-selftest.$name.out)"
    fail=1
  fi
done

if [ "$count" -eq 0 ]; then
  echo "gatephase-selftest: no tests/gatephase_ac*.sh cases found" >&2
  exit 1
fi

echo "----"
echo "gatephase-selftest: $count case(s), $([ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "FAILURES ABOVE")"
exit "$fail"
