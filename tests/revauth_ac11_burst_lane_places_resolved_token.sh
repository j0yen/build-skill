#!/usr/bin/env bash
# revauth_ac11_burst_lane_places_resolved_token.sh — PRD-build-reviewer-
# agent-auth-contract AC11.
#
# Given `burst-lane.sh` places the reviewer credential on a box (fake
# ssh/rsync doubles), When placement runs with no CLAUDE_CODE_OAUTH_TOKEN in
# the environment and REVIEWER_AUTH_FILE (via BURST_CLAUDE_CRED_SRC) holding
# the fixture token, Then the remote receives a KEY=value file at the
# remote REVIEWER_AUTH_FILE-shaped path containing the fixture token, no
# credentials.json is pushed, and `down` shreds that file (journal
# `cred  shredded`).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  revauth AC11: up succeeds resolving the token by the named order" \
  "ok  revauth AC11: the remote received exactly one KEY=value CLAUDE_CODE_OAUTH_TOKEN line" \
  "ok  revauth AC11: the placed credential is mode 0600" \
  "ok  revauth AC11: journal records the placement with source=environment.d" \
  "ok  revauth AC11: down deletes cleanly" \
  "ok  revauth AC11: the credential file is gone from the fake box after down" \
  "ok  revauth AC11: journal has 'cred  shredded'" \
  "ok  revauth AC11: the fixture token never appears in the journal"
