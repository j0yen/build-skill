#!/usr/bin/env bash
# probevis_ac8_probe_bounded_by_timeout.sh —
# PRD-build-burst-probe-visibility AC8.
#
# Given a fixture probe whose third tool's --version hangs, When the probe
# runs, Then the hang is bounded by the per-tool timeout, the sweep still
# reports all 8 tools, and no tool is silently dropped. Proven structurally
# (see the dedicated fixture's own AC8 comment for why): the actual
# gate_tools_probe() command text wraps every --version call in a timeout
# and always emits the completion sentinel after the loop.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/probevis-ac-common.sh"
run_probevis_suite_and_expect_labels \
  "ok  AC8 setup: gate_tools_probe ran without error" \
  "ok  AC8: each --version call is bounded by a timeout wrapper" \
  "ok  AC8: the sweep always emits the completion sentinel after the loop"
