#!/usr/bin/env bash
# probevis_ac5_probe_disagreement_journaled.sh —
# PRD-build-burst-probe-visibility AC5.
#
# Given a fixture pre-probe reporting mold present and a final probe
# reporting mold missing, When provision runs, Then probe-disagreement
# (tool=mold pre="..." final="...") is journaled.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/probevis-ac-common.sh"
run_probevis_suite_and_expect_labels \
  "ok  AC5: probe-disagreement journaled for mold (present pre, missing final)"
