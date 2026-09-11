#!/usr/bin/env bash
# gatetc_ac1_toolchain_pin_installs_cargo_deny_nextest.sh —
# PRD-build-burst-gate-tools-toolchain AC1.
#
# Given a fake box listing toolchains 1.85.0 and 1.88.0 whose fake cargo
# fails unless invoked with +1.88.0, When `provision` (via `up`) runs, Then
# cargo-deny and cargo-nextest install and gate_ready=true.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatetc AC1: up succeeds (exit 0)" \
  "ok  gatetc AC1: gate_ready is true once cargo-deny/cargo-nextest install under +1.88.0" \
  "ok  gatetc AC1: journal records cargo-deny install rc=0" \
  "ok  gatetc AC1: journal records cargo-nextest install rc=0"
