#!/usr/bin/env bash
# reenable_ac14_reality_check_pending_run.sh — PRD-build-burst-dispatch-reenable AC14.
#
# Given a box reaching gate_ready=true on `up` and a pending box-only
# reality-check registration for build-skill, When `up` completes,
# Then `reality-check.sh pending-run build-skill` ran and the
# registration is consumed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC14a: session reached gate_ready=true (default fixture)" \
  "ok  reenable AC14a: up journals pending-reality-run (rc=0) with nothing pending" \
  "ok  reenable AC14b: the pending registration was consumed (file removed)" \
  "ok  reenable AC14b: a reality receipt was written for it" \
  "ok  reenable AC14b: reality-check's own journal records the verdict (tier=box)" \
  "ok  reenable AC14b: burst-lane's own up journals pending-reality-run (rc=0) too" \
  "ok  reenable AC14c setup: session is gate_ready=false" \
  "ok  reenable AC14c: no pending-reality-run was journaled while gate_ready=false" \
  "ok  reenable AC14c: the pending registration is left untouched"
