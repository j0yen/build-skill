#!/usr/bin/env bash
# opauth_ac7_authz_recorded_in_journal_and_proof.sh —
# PRD-build-operator-authorization-contract AC7.
#
# Given burst-lane.sh cmd_prove/cmd_up/cmd_bake running with a
# dispatch-supplied authorization string, When the command journals its
# outcome, Then the journal line and proof.json (when written) both carry
# the authorization string under an authz= field.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/opauth-burstlane-ac-common.sh"
run_burstlane_suite_and_expect_labels \
  "ok  opauth AC7: up with an authorization string still exits 0" \
  "ok  opauth AC7: the booted journal line carries authz=" \
  "ok  opauth AC7: bake with an authorization string exits 0" \
  "ok  opauth AC7: the bake-done journal line carries authz="
