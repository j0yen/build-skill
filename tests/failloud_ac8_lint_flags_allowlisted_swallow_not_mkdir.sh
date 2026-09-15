#!/usr/bin/env bash
# PRD-build-fail-loud-evidence-kept AC8: lint-fail-loud.sh reports
# file:line + the matched allowlist entry for `( cmd_down >/dev/null 2>&1
# ) || true`, and never flags the same redirect shape on a
# non-allowlisted command like `mkdir -p`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/failloud-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC8: the allowlisted swallow is reported with file:line and the entry" \
  "ok  AC8: the non-allowlisted mkdir -p shape is never reported" \
  "ok  AC8: hard mode (LINT_FAIL_LOUD_WARN=0) exits non-zero on a real offense"
