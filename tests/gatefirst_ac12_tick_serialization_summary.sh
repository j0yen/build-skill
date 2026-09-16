#!/usr/bin/env bash
# gatefirst_ac12_tick_serialization_summary.sh — PRD-build-gate-before-land
# AC12.
#
# Given a tick that admitted two same-target branches, When the tick ends,
# Then the journal holds one serialization: line with waits,
# land_lock_hold_max, and the branch/main/cached gate counts.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatefirst-ac-common.sh"
run_serialdigest_and_expect_labels \
  "ok  Part1: select-guard exits 1 (blocked by same-target cap)" \
  "ok  Part1: a same-target-blocked journal line was written" \
  "ok  Part1: blocked line names the target and cap" \
  "ok  Part1: a same-target-admit journal line was written" \
  "ok  Part2: digest exits 0" \
  "ok  Part2: waits=2 (two same-target-blocked lines)" \
  "ok  Part2: land_lock_hold_max=27s (max of 3/27/9)" \
  "ok  Part2: gates branch=2 (two scope=branch, non-cached, real runs)" \
  "ok  Part2: gates main=1 (one non-cached main-scope run; route-mismatch/record-baseline excluded)" \
  "ok  Part2: cached=1 (one (cached tree=...) line)" \
  "ok  Part3: digest exits 0 on a missing journal" \
  "ok  Part3: all-zero line"
