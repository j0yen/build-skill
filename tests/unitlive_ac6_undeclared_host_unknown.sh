#!/usr/bin/env bash
# unitlive_ac6_undeclared_host_unknown.sh — PRD-buildloop-unit-liveness AC6.
#
# Given a host with no lines in loop-units.txt, when loop-liveness.sh
# runs, then it prints `LIVENESS unknown host=<h>` and exits 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/unitlive-ac-common.sh"
run_unitlive_suite_and_expect_labels \
  "ok  unitlive_ac6: undeclared host -> LIVENESS unknown, exit 0"
