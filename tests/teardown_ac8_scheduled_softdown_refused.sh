#!/usr/bin/env bash
# teardown_ac8_scheduled_softdown_refused.sh — PRD-build-burst-teardown-
# evidence AC8.
#
# Given `down --at 06:48`, when it runs, then it exits 2, creates no timer,
# and journals down refused (cause=scheduled-teardown-disabled).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  teardown AC8: down --at exits 2" \
  "ok  teardown AC8: no timer/systemd-run call was ever made for this" \
  "ok  teardown AC8: the refusal is journaled with cause=scheduled-teardown-disabled"
