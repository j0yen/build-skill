#!/usr/bin/env bash
# reality_ac2_reachable_run_writes_ok_and_receipt.sh —
# PRD-build-post-ship-reality-check AC2.
#
# Given a plan and a fake lane reporting an active session, When
# `reality-check.sh run` executes, Then the fake command runs, the archived
# PRD's frontmatter gains `reality: ok` and `reality_receipt:`, and the
# journal has `reality  <slug>  ok`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reality AC2: reachable+passing run exit 0" \
  "ok  reality AC2: reality_receipt frontmatter present and file exists" \
  "ok  reality AC2: journal has 'reality  realityfix  ok'"
