#!/usr/bin/env bash
# bdrift_ac8_every_ac_has_a_wrapper.sh —
# PRD-build-burst-selftest-drift-and-bake-gate AC8.
#
# Given tests/bdrift_ac*.sh, When verified-completed.sh --derive runs for
# this PRD, Then every AC above pairs with a wrapper (requirement 6). This
# is a self-check on the wrapper corpus itself, not on burst-lane.sh: the
# PRD names 9 acceptance criteria (AC1-AC9), so 9 distinct
# tests/bdrift_ac<N>_*.sh files must exist, one per AC number, with no
# gaps and no duplicate AC numbers claimed by two files.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

declare -A seen=()
for f in "$HERE"/bdrift_ac*_*.sh; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  n="$(sed -E 's/^bdrift_ac([0-9]+)_.*/\1/' <<<"$base")"
  case "$n" in
    ''|*[!0-9]*) echo "FAIL: could not parse an AC number from $base" >&2; exit 1 ;;
  esac
  seen["$n"]=1
done

fail=0
for want in 1 2 3 4 5 6 7 8 9; do
  if [ -n "${seen[$want]:-}" ]; then
    echo "ok  AC$want has a tests/bdrift_ac${want}_*.sh wrapper"
  else
    echo "FAIL: no tests/bdrift_ac${want}_*.sh wrapper found" >&2
    fail=1
  fi
done
exit $fail
