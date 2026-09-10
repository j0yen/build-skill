#!/usr/bin/env bash
# gatetools_ac2_copy_fails_lane_stays_verified.sh —
# PRD-build-burst-gate-tools-scope AC2.
#
# Given a fake box where the autobuilder copy fails, When `verify` runs,
# Then it reports `verified=true gate_ready=false`, journals
# `verify  gate-tools-missing  (missing=autobuilder)`, and
# `run <worktree> -- cargo build` still routes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatetools AC2: verify exits 0 (lane checks alone decide verified) even though gate-tools failed" \
  "ok  gatetools AC2: session state is verified:true" \
  "ok  gatetools AC2: session state is gate_ready:false" \
  "ok  gatetools AC2: verify journals gate-tools-missing naming autobuilder" \
  "ok  gatetools AC2: run <worktree> -- cargo build still routes despite gate_ready=false"
