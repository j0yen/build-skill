#!/usr/bin/env bash
# unitlive_ac2_all_active_ok.sh — PRD-buildloop-unit-liveness AC2.
#
# Given all six reported active, when loop-liveness.sh runs, then it
# prints `LIVENESS ok n=6`, exits 0, and the state file has no line for
# any unit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/unitlive-ac-common.sh"
run_unitlive_suite_and_expect_labels \
  "ok  unitlive_ac2: all active -> LIVENESS ok n=6, exit 0, empty state file"
