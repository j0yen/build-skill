#!/usr/bin/env bash
# gatetools_ac4_provision_reprovisions_without_reboot.sh —
# PRD-build-burst-gate-tools-scope AC4.
#
# Given `gate_ready=false`, When `burst-lane.sh provision` runs against a
# fake box where the copy now succeeds, Then `gate_ready=true` without a
# reboot and `status` shows `missing=` empty.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatetools AC4 setup: gate_ready:false after up (copy failed)" \
  "ok  gatetools AC4: provision exits 0 once the retried install succeeds" \
  "ok  gatetools AC4: gate_ready becomes true without a reboot" \
  "ok  gatetools AC4: no additional hcloud server create call happened" \
  "ok  gatetools AC4: status shows missing= empty"
