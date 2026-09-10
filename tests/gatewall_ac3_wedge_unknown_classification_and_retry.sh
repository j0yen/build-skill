#!/usr/bin/env bash
# gatewall_ac3_wedge_unknown_classification_and_retry.sh — PRD-build-gate-wall-clock AC3.
#
# Given a fixture step sleeping at zero CPU past its budget, When the
# wedge probe fires, Then the step's tree is killed by exact PIDs,
# wedge-receipt.json has the CPU-delta and wchan tables, classification
# is `unknown`, and one retry runs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatewall-ac-common.sh"
run_suite_and_expect_labels gate-wedge-selftest.sh \
  "ok  AC3 exit 98 (both attempts wedged)" \
  "ok  AC3 exactly 2 receipts written" \
  "ok  AC3 classification is unknown" \
  "ok  AC3 receipt has cpu_delta_table" \
  "ok  AC3 receipt has wchan_table" \
  "ok  AC3 no leaked sleep-600 process remains"
