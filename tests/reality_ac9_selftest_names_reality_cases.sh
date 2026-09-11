#!/usr/bin/env bash
# reality_ac9_selftest_names_reality_cases.sh —
# PRD-build-post-ship-reality-check AC9.
#
# Given the selftest fixture set, When `burst-lane-selftest.sh` runs, Then
# it exits 0 and names the `reality` cases.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reality AC1: plan lists AC1 kind=box with the literal parity command" \
  "ok  reality AC9: every reality case above ran green"
