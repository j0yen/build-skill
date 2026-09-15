#!/usr/bin/env bash
# gatelaunch_ac2_wait_returns_gate_rc.sh —
# PRD-build-gate-launch-survives-tick AC(b).
#
# Given --wait, when the fake extend-gate.sh exits pass (0) or block (1),
# then gate-launch.sh --wait relays that exact exit code — read via
# gate-status.sh's LoadState-then-receipts logic, never a raw
# ExecMainStatus read that can lie once --collect unloads the unit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatelaunch-ac-common.sh"
run_suite_and_expect_labels \
  "ok  pass fixture: --wait exits 0" \
  "ok  block fixture: --wait exits 1"
