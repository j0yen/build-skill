#!/usr/bin/env bash
# gatebox_ac10_selftest_names_gatebox_cases.sh — PRD-build-gate-on-casper AC10.
#
# Given the selftest fixture set, When `burst-lane-selftest.sh` runs, Then
# it exits 0 and names the `gatebox` cases -- one representative label per
# AC1-AC9 (the full set is exercised by the other
# tests/gatebox_ac<N>_*.sh wrappers; this one asserts the suite as a whole
# reports every AC number, not just any one of them).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatebox AC1: verify reports 'gate-tools ok'" \
  "ok  gatebox AC2: gate prints fallback: parity-diff" \
  "ok  gatebox AC3: journal gate line names the verdict, host, and wall time" \
  "ok  gatebox AC4: the sentinel token never appears in the journal" \
  "ok  gatebox AC5: gate prints fallback: <cause>" \
  "ok  gatebox AC6: a third call for the SAME repo waited for the first to finish (no overlap)" \
  "ok  gatebox AC7 (past budget): journal has 'gate  abandoned' naming host and age" \
  "ok  gatebox AC8: gate prints fallback: remote-disabled" \
  "ok  gatebox AC9: the daily rollup line carries gates_remote=2 gates_local=1"
