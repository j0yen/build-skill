#!/usr/bin/env bash
# opauth_ac9_undispatched_no_authz_unaffected.sh —
# PRD-build-operator-authorization-contract AC9.
#
# Given burst-lane.sh cmd_prove/cmd_up/cmd_bake invoked with no
# dispatch-context marker (a direct human-run invocation) and no
# authorization string present, When the command runs, Then it proceeds
# exactly as it does today (no new refusal for the human-at-keyboard path).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/opauth-burstlane-ac-common.sh"
run_burstlane_suite_and_expect_labels \
  "ok  opauth AC9: undispatched up with no authorization still exits 0" \
  "ok  opauth AC9: undispatched up still creates a server" \
  "ok  opauth AC9: no refusal was journaled"
