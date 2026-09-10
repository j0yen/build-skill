#!/usr/bin/env bash
# gatebox_ac1_up_provisions_gate_toolchain.sh — PRD-build-gate-on-casper AC1.
#
# Given a fresh fake box missing `autobuilder` and `jq`, When
# `burst-lane.sh up` runs, Then session state records `gate_ready: true`
# with a version for every tool in requirement 1, and `verify` reports
# `gate-tools ok`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatebox AC1: up succeeds even though autobuilder+jq start missing" \
  "ok  gatebox AC1: session state records gate_ready:true after provisioning" \
  "ok  gatebox AC1: gate-tools.json records a version for every requirement-1 tool" \
  "ok  gatebox AC1: verify exits 0 once gate-tools (and everything else) is provisioned" \
  "ok  gatebox AC1: verify reports 'gate-tools ok'"
