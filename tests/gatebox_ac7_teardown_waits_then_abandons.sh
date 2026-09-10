#!/usr/bin/env bash
# gatebox_ac7_teardown_waits_then_abandons.sh — PRD-build-gate-on-casper AC7.
#
# Given a remote gate still running at teardown, When the watchdog fires,
# Then it waits up to the gate's budget, pulls receipts, journals
# `gate  <repo>  <verdict>`, then deletes; given a gate past budget, Then
# it journals `gate  abandoned`, invalidates `last-verdict.json`, and
# deletes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatebox AC7 (finishes in time): down still deletes the box" \
  "ok  gatebox AC7 (finishes in time): journal has 'gate  pass' with waited=true" \
  "ok  gatebox AC7 (past budget): down still deletes the box" \
  "ok  gatebox AC7 (past budget): journal has 'gate  abandoned' naming host and age" \
  "ok  gatebox AC7 (past budget): the stale last-verdict.json was invalidated"
