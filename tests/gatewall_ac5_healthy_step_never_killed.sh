#!/usr/bin/env bash
# gatewall_ac5_healthy_step_never_killed.sh — PRD-build-gate-wall-clock AC5.
#
# Given a fixture step whose CPU advances, When it runs 6 min, Then it is
# not killed and no wedge receipt is written. (Selftest uses a
# proportionally shortened budget/probe window, per gate-wedge-selftest.sh's
# own env overrides, to keep the suite fast — same fixture-only discipline
# as every other AC here.)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatewall-ac-common.sh"
run_suite_and_expect_labels gate-wedge-selftest.sh \
  "ok  AC5 exit 0 (never killed)" \
  "ok  AC5 command's own output passed through" \
  "ok  AC5 no wedge receipt written" \
  "ok  AC5 wedges=0 reported"
