#!/usr/bin/env bash
# paritycad_ac6_selftest_names_own_cases.sh — PRD-build-burst-parity-cadence
# AC6 (P1).
#
# Given the selftest fixture set, When `burst-lane-selftest.sh` runs, Then
# it exits 0 and names the `paritycad` cases.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  paritycad AC6: every paritycad case above ran green"
