#!/usr/bin/env bash
# gatetc_ac3_per_tool_install_and_apt_update_journaled.sh —
# PRD-build-burst-gate-tools-toolchain AC3.
#
# Given any provision run, When it completes, Then the journal has one
# `gate-tools  install` line per attempted tool and one `apt-update`
# record — both when an apt tool was missing (ran=true) and when none was
# (ran=false, AC3b — the same "attempted but not silently skipped" bar
# requirement 2 sets for individual tools).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatetc AC3: exactly one apt-update record for this provision" \
  "ok  gatetc AC3: apt-update record says ran=true (an apt tool was missing)" \
  "ok  gatetc AC3: exactly one install line for jq" \
  "ok  gatetc AC3: exactly one install line for mold" \
  "ok  gatetc AC3: exactly one install line for gh" \
  "ok  gatetc AC3b: exactly one apt-update record when no apt tool is missing" \
  "ok  gatetc AC3b: apt-update record says ran=false"
