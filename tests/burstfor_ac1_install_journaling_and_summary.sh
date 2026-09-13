#!/usr/bin/env bash
# burstfor_ac1_install_journaling_and_summary.sh — PRD-build-burst-provision-forensics AC1.
#
# Given fixture installers where tool 3 (gh) exits 1, when provision runs,
# then the journal contains install-start for all 8 tools, install-failed
# (tool=gh ...) with the fixture's stderr FIRST line, terminal install
# lines for tools 4-8, and the summary lists a per-tool rc for all 8.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burstfor-ac-common.sh"
run_burstfor_suite_and_expect_labels \
  "ok  AC1: provision exits 1 (gh still missing)" \
  "ok  AC1: install-start journaled for tool=autobuilder" \
  "ok  AC1: install-start journaled for tool=jq" \
  "ok  AC1: install-start journaled for tool=gh" \
  "ok  AC1: install-start journaled for tool=mold" \
  "ok  AC1: install-start journaled for tool=cargo-deny" \
  "ok  AC1: install-start journaled for tool=cargo-nextest" \
  "ok  AC1: install-start journaled for tool=uv" \
  "ok  AC1: install-start journaled for tool=claude" \
  "ok  AC1: gh gets install-failed with rc=17" \
  "ok  AC1 (requirement 1): err= is the FIRST stderr line, not the last" \
  "ok  AC1: terminal install line (not install-failed) for tool=mold" \
  "ok  AC1: terminal install line (not install-failed) for tool=cargo-deny" \
  "ok  AC1: terminal install line (not install-failed) for tool=cargo-nextest" \
  "ok  AC1: terminal install line (not install-failed) for tool=uv" \
  "ok  AC1: terminal install line (not install-failed) for tool=claude" \
  "ok  AC1: summary line lists a per-tool rc for all 8" \
  "ok  AC1: provision's own stdout also carries per_tool_rc"
