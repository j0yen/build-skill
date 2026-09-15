#!/usr/bin/env bash
# PRD-build-fail-loud-evidence-kept AC6: probe_bg returns immediately, and
# a backgrounded child's exit code (rc=3, two seconds later) reaches the
# journal as `probe  bg-exit  (name=parity rc=3)` within 5 seconds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/failloud-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC6: probe_bg returns immediately (parent not blocked ~2s)" \
  "ok  AC6: bg-exit (name=parity rc=3) journaled within 5s"
