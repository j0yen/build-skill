#!/usr/bin/env bash
# teardown_ac9_status_next_teardown.sh — PRD-build-burst-teardown-evidence
# AC9.
#
# Given a live box, when status --json runs, then next_teardown.eta_s and
# next_teardown.cause are present and match teardown_decision --dry-run;
# polling status --json never appends to decisions.jsonl (a dry-run has no
# side effects).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  teardown AC9: status --json's next_teardown.decision is present and matches a dry-run" \
  "ok  teardown AC9: status --json's next_teardown.cause matches a dry-run" \
  "ok  teardown AC9: polling status --json never appends to decisions.jsonl (dry-run has no side effects)"
