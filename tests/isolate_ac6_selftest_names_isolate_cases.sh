#!/usr/bin/env bash
# isolate_ac6_selftest_names_isolate_cases.sh —
# PRD-build-burst-selftest-isolation AC6 (P1): burst-lane-selftest.sh exits
# 0 and names the isolate cases.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/isolate-ac-common.sh"
run_suite_and_expect_labels \
  "ok  isolate AC6: every isolate case above ran green"
