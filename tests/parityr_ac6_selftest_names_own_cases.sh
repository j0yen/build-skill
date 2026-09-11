#!/usr/bin/env bash
# parityr_ac6_selftest_names_own_cases.sh — PRD-build-burst-parity-robust
# AC6 (P1).
#
# Given the selftest fixture set, When `burst-lane-selftest.sh` runs, Then
# it exits 0 and names the `parityr` cases.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  parityr AC6: every parityr case above ran green"
