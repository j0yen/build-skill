#!/usr/bin/env bash
# probevis_ac2_present_tool_install_skipped.sh —
# PRD-build-burst-probe-visibility AC2.
#
# Given a fixture probe reporting gh present, When provision runs, Then
# gh journals install-skipped (tool=gh reason=present version="...") and
# is never installed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/probevis-ac-common.sh"
run_probevis_suite_and_expect_labels \
  "ok  AC2: gh journals install-skipped with reason=present and its version" \
  "ok  AC2: gh never gets install-start"
