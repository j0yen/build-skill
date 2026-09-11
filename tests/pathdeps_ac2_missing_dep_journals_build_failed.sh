#!/usr/bin/env bash
# pathdeps_ac2_missing_dep_journals_build_failed.sh — PRD-build-burst-path-deps
# AC2.
#
# Given a remote run whose cargo fails to resolve a dependency, When it
# exits, Then the journal has `run  build-failed  (cause=…)` and the
# attribution row has `phase=build`, and no `exit=101 phase=test` row is
# written.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  pathdeps AC2: run against a crate with a missing path dep exits nonzero" \
  "ok  pathdeps AC2: journal has a build-failed line naming the cause" \
  "ok  pathdeps AC2: no exit=101 phase=test row was written for this failure" \
  "ok  pathdeps AC2: attribution ledger row for this run carries phase=build"
