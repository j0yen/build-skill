#!/usr/bin/env bash
# provefx_ac2_run_aborted_term_signal.sh — PRD-build-burst-prove-forensics
# AC2.
#
# Given the same fixture, When prove is sent TERM during the run step, Then
# proof.json reads cause=run-aborted, down ran, and prove's exit code is
# 143.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC2: prove's exit code is 143 when killed with TERM during run" \
  "ok  provefx AC2: proof.json cause=run-aborted after the TERM abort" \
  "ok  provefx AC2: down ran after the TERM abort"
