#!/usr/bin/env bash
# reenable_ac5_prove_succeeds_routed.sh — PRD-build-burst-dispatch-reenable AC5.
#
# Given a fake session where run, pull and receipt all succeed with
# `cargo_route.host` equal to the box hostname, When `prove` runs, Then
# `proof.json` has routed=true, bytes>0, the journal has `prove done`,
# and `down` was called.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC5: prove exits 0 when run+pull+freshness+host all check out" \
  "ok  reenable AC5: proof.json has routed=true and bytes>0" \
  "ok  reenable AC5: journal has prove done" \
  "ok  reenable AC5: down ran at the end of prove (a decision line was journaled)"
