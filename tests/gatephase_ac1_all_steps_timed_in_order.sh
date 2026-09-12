#!/usr/bin/env bash
# gatephase_ac1_all_steps_timed_in_order.sh — PRD-build-gate-phase-timing AC1.
#
# Given a fake autobuilder whose ci-checks sleeps 2s and gate sleeps 3s and
# fake review steps that sleep 1s each, when extend-gate.sh runs, then the
# journal line contains phases=ci-checks:2,gate:3,reviewer:1,vti-plan:1,...
# (±1s each) after wall=, in invocation order.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatephase-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC1: extend-gate.sh exits 0 on an all-pass fake gate" \
  "ok  AC1: journal line carries a phases= field after wall=" \
  "ok  AC1: phase risk-gate reads skip" \
  "ok  AC1: phase intake = 0s" \
  "ok  AC1: phase proof-receipt = 0s" \
  "ok  AC1: phase vti-plan = 1s" \
  "ok  AC1: phase rollback-plan = 0s" \
  "ok  AC1: phase ci-checks = 2s" \
  "ok  AC1: phase receipts = 0s" \
  "ok  AC1: phase reviewer = 1s" \
  "ok  AC1: phase gate = 3s" \
  "ok  AC1: phases are in invocation order"
