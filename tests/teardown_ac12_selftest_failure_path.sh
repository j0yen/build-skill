#!/usr/bin/env bash
# teardown_ac12_selftest_failure_path.sh — PRD-build-burst-teardown-evidence
# AC12 (P1).
#
# Given the teardown selftest, when it runs, then every fixture case above
# (AC1-AC9, AC1/AC7/AC10/AC11 deferred with justification) passes, and one
# case asserts the failure path where decisions.jsonl is missing a row for
# a deleted id: why-down prints "no decision recorded" and journals
# `teardown  unrecorded-deletion  (server_id=<id>)`.
#
# Shares its fixture case with teardown_ac6 (why-down's own AC6 proof
# naturally produces the AC12 failure-path case in the same block) — see
# that file's own header.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  teardown AC6/AC12: an id with no decisions.jsonl row prints no decision recorded" \
  "ok  teardown AC6/AC12: that case is a real failure exit, not a tautological 0" \
  "ok  teardown AC12: the unrecorded deletion is itself journaled as a defect" \
  "ok  teardown: every teardown case above ran green"
