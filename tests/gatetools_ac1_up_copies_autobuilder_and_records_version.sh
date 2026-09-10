#!/usr/bin/env bash
# gatetools_ac1_up_copies_autobuilder_and_records_version.sh —
# PRD-build-burst-gate-tools-scope AC1.
#
# Given a fake box without `autobuilder`, When `up` runs, Then the fake scp
# (rsync, a real local `cp` under this offline harness) is called for
# `~/.cargo/bin/autobuilder` and session state records its version.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatetools AC1: up succeeds with autobuilder initially missing" \
  "ok  gatetools AC1: the autobuilder binary was copied (rsync) to the remote cargo bin dir" \
  "ok  gatetools AC1: session state records autobuilder's version once provisioned"
