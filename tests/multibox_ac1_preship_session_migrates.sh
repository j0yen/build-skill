#!/usr/bin/env bash
# multibox_ac1_preship_session_migrates.sh — PRD-build-burst-state-keyed-by-
# server-v2 AC1.
#
# Given a pre-ship top-level session.json for box 111, When any command
# runs, Then boxes/111/session.json exists, current points to it, the
# journal has `state  migrated`, and status --json .server_id is 111.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  multibox AC1: boxes/111/session.json exists after migration" \
  "ok  multibox AC1: current points at boxes/111" \
  "ok  multibox AC1: journal has 'state  migrated'" \
  "ok  multibox AC1: status --json .server_id is 111"
