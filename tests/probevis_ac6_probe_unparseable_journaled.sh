#!/usr/bin/env bash
# probevis_ac6_probe_unparseable_journaled.sh —
# PRD-build-burst-probe-visibility AC6.
#
# Given a fixture probe that exits non-zero or returns unparseable output,
# When provision runs, Then probe-unparseable is journaled and the
# fallback missing-list state is distinguishable in the journal from a
# measured result.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/probevis-ac-common.sh"
run_probevis_suite_and_expect_labels \
  "ok  AC6: probe-unparseable journaled for phase=pre" \
  "ok  AC6: probe-unparseable journaled for phase=final" \
  "ok  AC6: the fallback missing-list covers every tool (never a partial/measured-looking result)"
