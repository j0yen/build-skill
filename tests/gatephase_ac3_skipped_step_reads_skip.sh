#!/usr/bin/env bash
# gatephase_ac3_skipped_step_reads_skip.sh — PRD-build-gate-phase-timing AC3.
#
# Given a step the gate skips by configuration (no scripts/audit.sh in the
# fixture; gh not authenticated), when the gate runs, then the phase reads
# <name>:skip.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatephase-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC3: risk-gate reads skip (no scripts/audit.sh in the fixture), got skip" \
  "ok  AC3: ci-checks reads skip when gh is not authenticated, got skip"
