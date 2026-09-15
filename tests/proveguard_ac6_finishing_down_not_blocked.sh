#!/usr/bin/env bash
# proveguard_ac6_finishing_down_not_blocked.sh — PRD-build-burst-prove-
# inflight-guard AC6.
#
# Given a fixture prove that completes (any outcome) through its own
# NORMAL end-of-function tail (not the abort trap AC5 already covers), When
# prove's own finishing `down` call runs, Then the box is actually deleted
# and the journal carries prove's own down decision — never
# decision=keep(cause=prove-inflight) against its own still-alive pid (real
# run 2026-09-15T05:08:20Z, box 165983860 left running with pid 4191204 —
# prove itself — named as the "live" holder).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  proveguard AC6: the fixture prove itself completes (routed)" \
  "ok  proveguard AC6: proof.json names the server_id prove created" \
  "ok  proveguard AC6: prove.inflight is gone" \
  "ok  proveguard AC6: the journal has prove's own down decision, never decision=keep cause=prove-inflight"
