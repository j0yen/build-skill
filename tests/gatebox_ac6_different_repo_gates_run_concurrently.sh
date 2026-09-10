#!/usr/bin/env bash
# gatebox_ac6_different_repo_gates_run_concurrently.sh — PRD-build-gate-on-casper AC6.
#
# Given two `gate` calls for different repos with sub-cap 7, When they run
# together, Then both proceed concurrently and `status --json` lists two
# gates; a third call for one of the same repos waits on that repo's lock.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatebox AC6: status --json lists two gates while both are in flight" \
  "ok  gatebox AC6: all three gate calls eventually exit 0" \
  "ok  gatebox AC6: the two different-repo gates actually overlapped (concurrent, not serialized)" \
  "ok  gatebox AC6: a third call for the SAME repo waited for the first to finish (no overlap)"
