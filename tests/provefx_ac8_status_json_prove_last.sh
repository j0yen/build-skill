#!/usr/bin/env bash
# provefx_ac8_status_json_prove_last.sh — PRD-build-burst-prove-forensics
# AC8.
#
# Given any prove outcome, When status --json runs, Then prove_last reports
# ts, outcome, step, cause, line, log.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC8: status --json prove_last.outcome is failed for an up-failed prove" \
  "ok  provefx AC8: status --json prove_last.step names the failing step" \
  "ok  provefx AC8: status --json prove_last.cause matches proof.json" \
  "ok  provefx AC8: status --json prove_last.log names an existing prove.<epoch>.up.log" \
  "ok  provefx AC8: status --json prove_last is null when prove has never run"
