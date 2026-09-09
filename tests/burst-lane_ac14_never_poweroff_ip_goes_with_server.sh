#!/usr/bin/env bash
# burst-lane_ac14_never_poweroff_ip_goes_with_server.sh —
# PRD-build-burst-lane-ccx53 AC14.
#
# Given a session, when any subcommand runs, then no
# hcloud server poweroff|shutdown|stop|reboot call is ever issued, and
# down's deletion removes the server's primary IP in the same step.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  no poweroff/shutdown/stop/reboot call was ever made" \
  "ok  server create never attaches a standalone primary IP (--primary-ipv4)" \
  "ok  no separate primary-ip create call was ever made (would outlive server delete)" \
  "ok  no separate primary-ip delete call was needed (server delete already took it)"
