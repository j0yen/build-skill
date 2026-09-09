#!/usr/bin/env bash
# burst-lane_ac1_up_twice_adopts.sh — PRD-build-burst-lane-ccx53 AC1.
#
# Given the fake hcloud selftest, when burst-lane.sh up runs twice, then one
# server is created and the second call adopts it and exits 0 without a
# create call (also covers the lost-state adoption path: a session.json
# lost while the server itself is still alive never double-creates).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  first up creates a server (exit 0)" \
  "ok  exactly one create call so far" \
  "ok  second up adopts, exits 0" \
  "ok  second up reports already-up, no new create" \
  "ok  second up made no additional create call" \
  "ok  up with lost state adopts existing server (exit 0)" \
  "ok  adoption made no create call" \
  "ok  adoption journaled"
