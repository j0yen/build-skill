#!/usr/bin/env bash
# reenable_ac6_prove_fails_not_routed.sh — PRD-build-burst-dispatch-reenable AC6.
#
# Given the same fake session but the receipt says host=<caller> or
# bytes=0 or no fresh artifact exists, When `prove` runs, Then
# `proof.json` has routed=false with the first failing check as cause,
# the command exits 1, and `down` was still called.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC6: prove exits 1 when the box's hostname matches the caller's" \
  "ok  reenable AC6: proof.json has routed=false with cause=host-mismatch" \
  "ok  reenable AC6: journal has prove failed (cause=host-mismatch)" \
  "ok  reenable AC6: down still ran even though the proof failed"
