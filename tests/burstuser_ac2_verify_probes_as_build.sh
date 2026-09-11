#!/usr/bin/env bash
# burstuser_ac2_verify_probes_as_build.sh — PRD-build-burst-unprivileged-user AC2.
#
# Given `up` complete, When `verify` runs, Then the cargo, uv, python,
# sandbox, and gate-tools probes all execute as build and pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstuser AC2: verify exits 0 (gate-tools-missing is informational only)" \
  "ok  burstuser AC2: the cargo/uv/python3 probe ran as build@" \
  "ok  burstuser AC2: the bwrap sandbox probe ran as build@" \
  "ok  burstuser AC2: no verify probe call targeted root@"
