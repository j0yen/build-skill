#!/usr/bin/env bash
# gatewall_ac2_sccache_assert_restart_or_fail.sh — PRD-build-gate-wall-clock AC2.
#
# Given the unit stopped, When a gate step with RUSTC_WRAPPER=sccache
# starts, Then sccache-assert.sh restarts it once and the step proceeds;
# Given the restart also fails, Then the step fails with sccache_unreachable
# and no compile runs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatewall-ac-common.sh"
run_suite_and_expect_labels sccache-assert-selftest.sh \
  "ok  case2 exit 0" \
  "ok  case2 restarted-once" \
  "ok  case2 ok restarted line" \
  "ok  case4 exit 1" \
  "ok  case4 sccache_unreachable"
