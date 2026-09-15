#!/usr/bin/env bash
# teardown_ac3_zero_runs_grace_formula.sh — PRD-build-burst-teardown-evidence
# AC3.
#
# Given a box with zero attribution rows, age 700s, Rust PRDs queued, and
# the loop active, when idle-guard's decision function runs, then the
# decision is keep cause=grace with evidence.grace_s >= 1200.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  teardown AC3: decision=keep" \
  "ok  teardown AC3: cause=grace" \
  "ok  teardown AC3: evidence.grace_s >= 1200"
