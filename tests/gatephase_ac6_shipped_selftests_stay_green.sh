#!/usr/bin/env bash
# gatephase_ac6_shipped_selftests_stay_green.sh — PRD-build-gate-phase-timing AC6.
#
# Given the shipped skill, when gate-debt.sh, manifest-invariants.sh, and
# ship-postconditions.sh selftests run against a journal with the new
# phases= field, then they are green.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatephase-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC6: gatedebt-selftest.sh (gate-debt.sh's own AC suite) stays green" \
  "ok  AC6: ship-postconditions.sh runs clean against the phase-timing fixture repo" \
  "ok  AC6: manifest-invariants.sh does not choke on a journal carrying phases="
