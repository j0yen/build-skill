#!/usr/bin/env bash
# teardown_ac5_stale_last_run_work_queued_keeps.sh — PRD-build-burst-
# teardown-evidence AC5.
#
# Given a box whose last routed run is 61 minutes old and Rust PRDs queued
# with the loop active, when teardown_decision() (the function `idle-guard`
# is meant to consult) runs, then the decision is keep cause=work-queued.
#
# NOTE: see teardown_ac4's own note — this exercises teardown_decision()
# directly; `idle-guard`'s own ACTING logic still only ever triggers on its
# pre-existing runs_served==0 condition this pass (requirement 2's full
# rewiring is a follow-on).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  teardown AC5: decision=keep" \
  "ok  teardown AC5: cause=work-queued"
