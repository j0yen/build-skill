#!/usr/bin/env bash
# gatewall_ac6_second_wedge_fails_with_two_receipts.sh — PRD-build-gate-wall-clock AC6.
#
# Given a step retried after a wedge that wedges again, When the second
# probe fires, Then the step fails with both receipts attached and the
# verdict receipt shows `wedges: 2`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatewall-ac-common.sh"
run_suite_and_expect_labels gate-wedge-selftest.sh \
  "ok  AC3 exit 98 (both attempts wedged)" \
  "ok  AC3 exactly 2 receipts written" \
  "ok  AC6 wedges=2 reported, never a third attempt"
