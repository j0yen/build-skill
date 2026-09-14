#!/usr/bin/env bash
# provefx_ac6_up_refused_names_live_holder.sh —
# PRD-build-burst-prove-forensics AC6.
#
# Given a fixture process holding up.lock and up.pid naming a different
# dead pid, When up runs, Then it refuses within 5s and the journal line
# names the fixture's pid and comm, not the dead pid.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC6: up refuses (exit 3) within 5s when a live fixture holds up.lock" \
  "ok  provefx AC6: refusal names the fixture's real, live pid, not the stale up.pid" \
  "ok  provefx AC6: refusal does NOT name the stale/dead pid from up.pid" \
  "ok  provefx AC6: refusal names a real comm for the fixture holder (not 'unknown')"
