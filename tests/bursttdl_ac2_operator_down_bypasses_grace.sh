#!/usr/bin/env bash
# bursttdl_ac2_operator_down_bypasses_grace.sh —
# PRD-build-burst-teardown-lifecycle AC2.
#
# Given a session in phase=setup inside the grace window, When an operator
# runs `down`, Then the box is deleted immediately despite the grace state
# — the grace protects against autonomous callers only, never against a
# human choosing to stop spending.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  bursttdl AC2 setup: the session is phase=setup, well inside the grace window" \
  "ok  bursttdl AC2: an operator's down deletes a phase=setup box immediately" \
  "ok  bursttdl AC2: the fake hcloud confirms the server is actually gone" \
  "ok  bursttdl AC2: no teardown-deferred line was ever journaled for this session"
