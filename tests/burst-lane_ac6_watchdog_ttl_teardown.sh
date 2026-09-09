#!/usr/bin/env bash
# burst-lane_ac6_watchdog_ttl_teardown.sh — PRD-build-burst-lane-ccx53 AC6.
#
# Given a session older than its TTL, when the watchdog ticks, then the
# server is deleted and the journal has a "watchdog teardown" line with
# uptime.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  watchdog deletes a session past its TTL" \
  "ok  watchdog journal line names uptime" \
  "ok  state cleared after watchdog teardown"
