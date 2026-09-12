#!/usr/bin/env bash
# gatephase_ac4_receipt_phases_wall_s_head.sh — PRD-build-gate-phase-timing AC4.
#
# Given a completed gate, when the receipt is read, then it has a phases
# object with every step, wall_s, and head, and the sum of phase seconds
# is within 5% of wall_s or unattributed is present.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatephase-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC4: last-verdict.json exists after a run" \
  "ok  AC4: receipt has a phases object with every step" \
  "ok  AC4: receipt has wall_s" \
  "ok  AC4: receipt has head" \
  "ok  AC4: no unattributed_s on a fully-timed run (sum within 5% of wall_s)"
