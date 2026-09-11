#!/usr/bin/env bash
# gatetc_ac4_parity_baseline_incomplete_not_diff.sh —
# PRD-build-burst-gate-tools-toolchain AC4.
#
# Given a box test run containing a suite absent from the local baseline,
# When `parity` runs, Then it refreshes the local baseline, journals
# `parity  baseline-refreshed`, and reports the suite as compared (ok or
# diff), never as a diff on a null local value.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatetc AC4: parity exits 0" \
  "ok  gatetc AC4: journal has 'parity  baseline-refreshed' naming the extra suite" \
  "ok  gatetc AC4: the refreshed local baseline file now has the extra suite" \
  "ok  gatetc AC4: parity reports diff=0 (the suite compared ok, not as a diff on a null)" \
  "ok  gatetc AC4: box-parity.json compares the extra suite ok/ok, not baseline-incomplete"
