#!/usr/bin/env bash
# provefx_ac10_reenable_block_still_green.sh —
# PRD-build-burst-prove-forensics AC10.
#
# Given the existing `reenable` selftest block, When the full selftest runs
# after this PRD, Then its prove cases (AC5, AC6 of dispatch-reenable)
# still pass and the whole block reads green.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC5: prove exits 0 when run+pull+freshness+host all check out" \
  "ok  reenable AC5: proof.json has routed=true and bytes>0" \
  "ok  reenable AC5: journal has prove done" \
  "ok  reenable AC5: down ran at the end of prove (a decision line was journaled)" \
  "ok  reenable AC6: prove exits 1 when the box's hostname matches the caller's" \
  "ok  reenable AC6: proof.json has routed=false with cause=host-mismatch" \
  "ok  reenable AC6: journal has prove failed (cause=host-mismatch)" \
  "ok  reenable AC6: down still ran even though the proof failed" \
  "ok  reenable: every reenable case above ran green"
