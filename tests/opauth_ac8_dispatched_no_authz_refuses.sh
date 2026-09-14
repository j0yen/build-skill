#!/usr/bin/env bash
# opauth_ac8_dispatched_no_authz_refuses.sh —
# PRD-build-operator-authorization-contract AC8.
#
# Given burst-lane.sh cmd_prove/cmd_up/cmd_bake invoked with the
# dispatch-context marker set and no authorization string present, When the
# command runs, Then it journals `refused cause=no-operator-authorization`
# and exits non-zero without attempting the underlying hcloud call.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/opauth-burstlane-ac-common.sh"
run_burstlane_suite_and_expect_labels \
  "ok  opauth AC8: dispatched up with no authorization exits non-zero" \
  "ok  opauth AC8: refusal names the cause on stderr" \
  "ok  opauth AC8: journal records the refusal" \
  "ok  opauth AC8: no hcloud server create call was ever attempted" \
  "ok  opauth AC8: no session.json was written" \
  "ok  opauth AC8: dispatched bake with no authorization exits non-zero" \
  "ok  opauth AC8: bake journal records the refusal" \
  "ok  opauth AC8: bake attempted no hcloud call" \
  "ok  opauth AC8: dispatched prove with no authorization exits non-zero" \
  "ok  opauth AC8: prove journal records the refusal" \
  "ok  opauth AC8: prove attempted no hcloud call" \
  "ok  opauth AC8: prove wrote no proof.json on the pre-hcloud refusal"
