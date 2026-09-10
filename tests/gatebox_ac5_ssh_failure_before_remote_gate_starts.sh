#!/usr/bin/env bash
# gatebox_ac5_ssh_failure_before_remote_gate_starts.sh — PRD-build-gate-on-casper AC5.
#
# Given the fake ssh/rsync fails before the remote gate starts, When
# `gate` runs, Then it exits 3, prints `fallback: <cause>`, and the
# journal has one `gate  fallback` line naming the cause.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatebox AC5: gate exits 3 when the rsync-up itself fails before the remote gate starts" \
  "ok  gatebox AC5: gate prints fallback: <cause>" \
  "ok  gatebox AC5: exactly one gate fallback journal line naming the cause"
