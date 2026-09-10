#!/usr/bin/env bash
# gatebox_ac8_burst_gate_remote_off_stays_local.sh — PRD-build-gate-on-casper AC8.
#
# Given `BURST_GATE_REMOTE=0`, When the tick's gate step runs with a
# session up, Then the gate runs locally and no `gate` remote line is
# journaled.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatebox AC8: gate exits 3 when BURST_GATE_REMOTE is unset (ships dark)" \
  "ok  gatebox AC8: gate prints fallback: remote-disabled" \
  "ok  gatebox AC8: journal has a gate fallback line naming cause=remote-disabled" \
  "ok  gatebox AC8: that journal line carries no host= field (it's not a remote line)" \
  "ok  gatebox AC8: the remote extend-gate.sh was never invoked" \
  "ok  gatebox AC8: BURST_GATE_REMOTE=0 (explicit) behaves the same as unset"
