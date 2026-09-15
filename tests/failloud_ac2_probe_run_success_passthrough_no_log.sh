#!/usr/bin/env bash
# PRD-build-fail-loud-evidence-kept AC2: a successful command's stdout
# passes through byte-identical, nothing is journaled, and no log file
# remains.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/failloud-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC2: stdout passes through byte-identical" \
  "ok  AC2: rc 0 on success" \
  "ok  AC2: no new journal line written on success" \
  "ok  AC2: no log file remains on success"
