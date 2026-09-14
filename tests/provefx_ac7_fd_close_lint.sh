#!/usr/bin/env bash
# provefx_ac7_fd_close_lint.sh — PRD-build-burst-prove-forensics AC7.
#
# Given a planted `( sleep 1 & )` without fd closes in a copy of
# burst-lane.sh, When the selftest lint runs, Then it fails naming the
# line; and When it runs on the real script, Then it passes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC7: the lint passes (0 violations) on the real, shipped burst-lane.sh" \
  "ok  provefx AC7: the lint fails naming >=1 violation on a planted unclosed background job" \
  "ok  provefx AC7: the lint names the exact planted line"
