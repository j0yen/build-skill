#!/usr/bin/env bash
# PRD-build-fail-loud-evidence-kept AC10: when one tool fails during
# provision_gate_tools, that tool's stderr log still exists under
# logs/failed/, and only the succeeded tools' own transient logs were
# removed. This behavior predates this PRD (PRD-build-burst-provision-
# forensics) and needed no code change — this proves the contract still
# holds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/failloud-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC10: the failed tool's stderr log survives under logs/failed/" \
  "ok  AC10: no transient install logs remain (succeeded tool's was removed)"
