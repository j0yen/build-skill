#!/usr/bin/env bash
# unitlive_ac4_tick_precheck_one_line.sh — PRD-buildloop-unit-liveness AC4.
#
# Given the tick pre-check runs on a tick that is skipped for no work,
# when it finishes, then build-auto.log has exactly one new LIVENESS
# line and the tick outcome is unchanged by the liveness exit code.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/unitlive-ac-common.sh"
run_buildhaswork_suite_and_expect_labels \
  "ok  case 7 (unitlive_ac4): exactly one new LIVENESS line appended on a skipped tick, exit code unaffected by liveness rc"
