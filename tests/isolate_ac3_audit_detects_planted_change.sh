#!/usr/bin/env bash
# isolate_ac3_audit_detects_planted_change.sh —
# PRD-build-burst-selftest-isolation AC3: a one-byte plant into a "live"
# journal mid-run is detected by the audit, which reports
# isolation-breach: naming it and returns non-zero.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/isolate-ac-common.sh"
run_suite_and_expect_labels \
  "ok  isolate AC3: the audit detects a one-byte planted change (nonzero exit)" \
  "ok  isolate AC3: it reports isolation-breach naming the journal"
