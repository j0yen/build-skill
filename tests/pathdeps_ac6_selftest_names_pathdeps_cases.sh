#!/usr/bin/env bash
# pathdeps_ac6_selftest_names_pathdeps_cases.sh — PRD-build-burst-path-deps
# AC6 (P1).
#
# Given the selftest fixture set, When `burst-lane-selftest.sh` runs, Then
# it exits 0 and names the `pathdeps` cases.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  pathdeps AC1: run against a crate with a sibling path dep exits 0" \
  "ok  pathdeps AC2: journal has a build-failed line naming the cause" \
  "ok  pathdeps AC3: verify exits 0 when the build user's registry is writable" \
  "ok  pathdeps AC4: the gate-tools probe ran as build@" \
  "ok  pathdeps AC6: every pathdeps case above ran green"
