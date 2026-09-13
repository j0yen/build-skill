#!/usr/bin/env bash
# bursttdl_ac3_grace_expiry_is_not_a_leak.sh —
# PRD-build-burst-teardown-lifecycle AC3.
#
# Given a session in phase=setup whose grace window has expired, When an
# autonomous caller (watchdog) runs, Then the box is deleted with
# cause=setup-grace-expired — a forgotten box cannot outlive the window.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  bursttdl AC3: an autonomous caller deletes once grace has expired" \
  "ok  bursttdl AC3: the deletion is journaled with cause=setup-grace-expired"
