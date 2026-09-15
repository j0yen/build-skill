#!/usr/bin/env bash
# PRD-build-fail-loud-evidence-kept AC1: a command that writes to stderr
# and exits 7, run via probe_run, returns rc 7, journals exactly one
# `probe  failed  (name=... rc=7 err="..." log=...)` line, and the log
# file contains the stderr.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/failloud-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC1: probe_run returns the command's own rc (7)" \
  "ok  AC1: one probe failed journal line with name/rc/err/log" \
  "ok  AC1: the kept log file contains the stderr (boom)"
