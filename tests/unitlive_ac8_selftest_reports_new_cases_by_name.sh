#!/usr/bin/env bash
# unitlive_ac8_selftest_reports_new_cases_by_name.sh — PRD-buildloop-unit-liveness AC8.
#
# Given the selftest fixture set, when the build selftest runs, then the
# `unitlive` cases are named and green — one representative label per
# AC1-AC6 (the full set is exercised by the other
# tests/unitlive_ac<N>_*.sh wrappers; this one asserts the suite as a
# whole reports every AC number, not just any one of them). AC4 lives in
# build-has-work-selftest.sh, not this suite, so it is covered by its own
# wrapper (unitlive_ac4_*.sh) instead of repeated here.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/unitlive-ac-common.sh"
run_unitlive_suite_and_expect_labels \
  "ok  unitlive_ac1: one inactive unit -> per-unit lines + one WARN line, exit 1" \
  "ok  unitlive_ac2: all active -> LIVENESS ok n=6, exit 0, empty state file" \
  "ok  unitlive_ac3a: after one inactive run, digest is empty" \
  "ok  unitlive_ac3b: after two consecutive inactive runs, digest names unit + first-seen time" \
  "ok  unitlive_ac5: loop-arm enables exactly the declared six, still-inactive unit -> non-zero exit" \
  "ok  unitlive_ac5b: loop-arm exits 0 once every declared unit is active" \
  "ok  unitlive_ac6: undeclared host -> LIVENESS unknown, exit 0"
