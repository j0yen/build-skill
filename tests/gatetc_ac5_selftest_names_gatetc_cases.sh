#!/usr/bin/env bash
# gatetc_ac5_selftest_names_gatetc_cases.sh —
# PRD-build-burst-gate-tools-toolchain AC5.
#
# Given the selftest fixture set, When `burst-lane-selftest.sh` runs, Then
# it exits 0 and names the `gatetc` cases — one representative label per
# AC1-AC4 (the full set is exercised by the other
# tests/gatetc_ac<N>_*.sh wrappers; this one asserts the suite as a whole
# reports every AC number, not just any one of them).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatetc AC1: gate_ready is true once cargo-deny/cargo-nextest install under +1.88.0" \
  "ok  gatetc AC2: journal has the exact install-failed line for mold" \
  "ok  gatetc AC3: exactly one apt-update record for this provision" \
  "ok  gatetc AC4: journal has 'parity  baseline-refreshed' naming the extra suite"
