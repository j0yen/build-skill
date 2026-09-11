#!/usr/bin/env bash
# gatetc_ac2_install_failed_journals_tool_rc_stderr.sh —
# PRD-build-burst-gate-tools-toolchain AC2.
#
# Given a fake box where the `mold` install exits 100 with stderr
# "E: Unable to locate package mold", When `provision` runs, Then the
# journal has `gate-tools  install-failed  (tool=mold rc=100 err="E: Unable
# to locate package mold")` and the summary line lists `mold`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatetc AC2: provision exits 1 (mold still missing)" \
  "ok  gatetc AC2: journal has the exact install-failed line for mold" \
  "ok  gatetc AC2: provision summary line lists mold in gate_tools_missing"
