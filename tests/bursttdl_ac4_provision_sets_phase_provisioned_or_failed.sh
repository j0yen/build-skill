#!/usr/bin/env bash
# bursttdl_ac4_provision_sets_phase_provisioned_or_failed.sh —
# PRD-build-burst-teardown-lifecycle AC4.
#
# Given a fake `provision` that fails, When it exits, Then the session is
# phase=failed and the next autonomous teardown deletes the box without
# waiting for grace. Also covers the success half: a successful provision
# moves phase to provisioned.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  bursttdl AC4: a successful provision moves phase to provisioned" \
  "ok  bursttdl AC4: a failed provision exits non-zero" \
  "ok  bursttdl AC4: a failed provision moves phase to failed" \
  "ok  bursttdl AC4: a phase=failed box is deleted by the very next autonomous caller, without waiting out any grace"
