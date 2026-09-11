#!/usr/bin/env bash
# isolate_ac2_live_audit_zero_diff.sh — PRD-build-burst-selftest-isolation
# AC2: given the sentinel and all overrides set to a fixture, the full
# selftest exits 0 and its before/after audit reports zero differences
# against the real live burst-lane state/journal (skipped-not-failed if an
# independently-running live session was already up before the suite
# started — see the note in burst-lane-selftest.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/isolate-ac-common.sh"
run_suite_and_expect_labels \
  "isolate AC2:"
