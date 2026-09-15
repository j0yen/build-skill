#!/usr/bin/env bash
# proveguard_ac5_marker_removed_after_prove.sh — PRD-build-burst-prove-
# inflight-guard AC5.
#
# Given a real (fixture) `prove` invocation that aborts mid-run, When it
# exits through prove_exit_trap, Then prove.inflight does not outlive the
# process — the marker's whole life is bounded by the trap, not by prove's
# own normal end-of-function cleanup.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  proveguard AC5: prove.inflight does not outlive an aborted fixture prove"
