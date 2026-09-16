#!/usr/bin/env bash
# multibox_ac13_tripwire_catches_new_path.sh — PRD-build-burst-state-keyed-
# by-server-v2 AC13.
#
# Given a fixture copy of burst-lane.sh with one added line
# NEW_THING="$STATE_DIR/new-thing.json", When the tripwire selftest runs,
# Then it fails and its output names new-thing.json; given the unmodified
# script and the checked-in surface file, When it runs, Then it passes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  multibox AC13/14: tripwire passes clean against the real script + surface file" \
  "ok  multibox AC13: tripwire fails on an unclassified new state path" \
  "ok  multibox AC13: tripwire names the new path"
