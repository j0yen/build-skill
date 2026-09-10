#!/usr/bin/env bash
# gatebox_ac4_reviewer_credential_placed_and_shredded.sh — PRD-build-gate-on-casper AC4.
#
# Given `BURST_GATE_REVIEWER=1` and a fake credential file containing a
# sentinel token, When `up` then `down` run, Then the credential exists on
# the fake box with mode 0600 between them, is absent after `down`, the
# journal has `cred  placed` and `cred  shredded`, and no file under the
# journal or receipts contains the sentinel.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatebox AC4: the credential exists on the fake box after up" \
  "ok  gatebox AC4: the placed credential is mode 0600" \
  "ok  gatebox AC4: journal has 'cred  placed'" \
  "ok  gatebox AC4: the credential is gone from the fake box after down" \
  "ok  gatebox AC4: journal has 'cred  shredded'" \
  "ok  gatebox AC4: the sentinel token never appears in the journal"
