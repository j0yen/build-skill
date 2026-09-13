#!/usr/bin/env bash
# probevis_ac1_probe_absent_omitted_tools_attempted.sh —
# PRD-build-burst-probe-visibility AC1.
#
# Given a fixture probe reporting jq=MISSING and omitting all other tools,
# When provision runs, Then every other tool journals probe-absent
# (tool=X) and is attempted, and no listed tool ends the run without a
# journal record.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/probevis-ac-common.sh"
run_probevis_suite_and_expect_labels \
  "ok  AC1: probe-absent journaled for omitted tool=autobuilder" \
  "ok  AC1: omitted tool=autobuilder is attempted (install-start)" \
  "ok  AC1: probe-absent journaled for omitted tool=gh" \
  "ok  AC1: omitted tool=gh is attempted (install-start)" \
  "ok  AC1: probe-absent journaled for omitted tool=mold" \
  "ok  AC1: omitted tool=mold is attempted (install-start)" \
  "ok  AC1: probe-absent journaled for omitted tool=cargo-deny" \
  "ok  AC1: omitted tool=cargo-deny is attempted (install-start)" \
  "ok  AC1: probe-absent journaled for omitted tool=cargo-nextest" \
  "ok  AC1: omitted tool=cargo-nextest is attempted (install-start)" \
  "ok  AC1: probe-absent journaled for omitted tool=uv" \
  "ok  AC1: omitted tool=uv is attempted (install-start)" \
  "ok  AC1: probe-absent journaled for omitted tool=claude" \
  "ok  AC1: omitted tool=claude is attempted (install-start)" \
  "ok  AC1: jq (genuinely reported MISSING) is also attempted"
