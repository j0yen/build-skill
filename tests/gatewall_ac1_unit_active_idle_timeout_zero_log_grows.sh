#!/usr/bin/env bash
# gatewall_ac1_unit_active_idle_timeout_zero_log_grows.sh — PRD-build-gate-wall-clock AC1.
#
# Given sccache-server.service installed, When systemctl --user status
# runs, Then the unit is active with SCCACHE_IDLE_TIMEOUT=0 in its
# environment and server.log exists and grows on a compile.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatewall-ac-common.sh"
run_suite_and_expect_labels sccache-unit-selftest.sh \
  "ok  tier1 unit sets SCCACHE_IDLE_TIMEOUT=0" \
  "ok  tier2 live unit env carries SCCACHE_IDLE_TIMEOUT=0" \
  "ok  tier2 live server.log exists" \
  "ok  tier2 server.log grows on a compile"
