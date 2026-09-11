#!/usr/bin/env bash
# pathdeps_ac3_verify_asserts_build_cargo_home.sh — PRD-build-burst-path-deps
# AC3.
#
# Given the build user on the fake box, When `verify` runs, Then it asserts
# `CARGO_HOME` under the build user's home with a writable registry and
# fails closed naming the path otherwise.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  pathdeps AC3: verify exits 0 when the build user's registry is writable" \
  "ok  pathdeps AC3: verify reports cargo-home ok, naming the build-home path" \
  "ok  pathdeps AC3: verify fails closed when the registry is not writable" \
  "ok  pathdeps AC3: the failure names the CARGO_HOME/registry path"
