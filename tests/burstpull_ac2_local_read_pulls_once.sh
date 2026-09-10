#!/usr/bin/env bash
# burstpull_ac2_local_read_pulls_once.sh — PRD-build-burst-pull-on-demand AC2.
#
# Given a dirty worktree, when a local cargo command runs through the shim
# layer, then exactly one pull executes before it, the marker clears, and
# the pull's attribution row records trigger local-read with the reading
# slug.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstpull AC2 setup: run left the worktree dirty" \
  "ok  burstpull AC2 setup: target/ not present yet" \
  "ok  burstpull AC2: shim ran local cargo (after the pull)" \
  "ok  burstpull AC2: one pull happened before the local cargo ran" \
  "ok  burstpull AC2: marker cleared after the local-read pull" \
  "ok  burstpull AC2: exactly one pull attribution row, trigger=local-read, reading slug (req 2)"
