#!/usr/bin/env bash
# burstuser_ac7_selftest_names_burstuser_cases.sh — PRD-build-burst-
# unprivileged-user AC7 (P1).
#
# Given the selftest fixture set, When `burst-lane-selftest.sh` runs, Then
# it exits 0 and names the `burstuser` cases.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstuser AC1: up exits 0" \
  "ok  burstuser AC2: verify exits 0 (gate-tools-missing is informational only)" \
  "ok  burstuser AC3: the remote cargo call targeted build@" \
  "ok  burstuser AC4: parity's remote cargo test call routed as build@" \
  "ok  burstuser AC5: the credential landed at the resolved cred path" \
  "ok  burstuser AC6: session.json now records remote_user=build" \
  "ok  burstuser AC7: every burstuser case above ran green (fail=0 through AC1-AC6)"
