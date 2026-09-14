#!/usr/bin/env bash
# provefx_ac1_run_aborted_unbound_var.sh — PRD-build-burst-prove-forensics
# AC1.
#
# Given a fixture session and a fixture cmd_run that dies on an unbound
# variable, When prove runs, Then proof.json exists with routed=false,
# cause=run-aborted, a numeric line, and the journal has one
# `prove aborted (step=run …)` line followed by `down`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC1: proof.json exists after an unbound-variable kill during run" \
  "ok  provefx AC1: proof.json has routed=false cause=run-aborted and step=run" \
  "ok  provefx AC1: exactly one prove-aborted journal line naming step=run" \
  "ok  provefx AC1: down ran after the abort" \
  "ok  provefx AC1: prove's own cost line is journaled with outcome=aborted"
