#!/usr/bin/env bash
# gatewall_ac7_receipt_carries_sccache_server_identity.sh — PRD-build-gate-wall-clock AC7.
#
# Given any gate step receipt post-ship, When read, Then it carries
# `sccache_server.pid` and `started_at`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatewall-ac-common.sh"
run_suite_and_expect_labels cargo-budget-sccache-selftest.sh \
  "PASS: case1: ledger row carries sccache_server.pid" \
  "PASS: case1: ledger row carries sccache_server.started_at"
