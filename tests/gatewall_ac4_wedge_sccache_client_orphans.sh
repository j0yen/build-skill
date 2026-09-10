#!/usr/bin/env bash
# gatewall_ac4_wedge_sccache_client_orphans.sh — PRD-build-gate-wall-clock AC4.
#
# Given a fixture step with a child recording a server pid that differs
# from the unit's MainPID, When the probe fires, Then classification is
# `sccache-client-orphans`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatewall-ac-common.sh"
run_suite_and_expect_labels gate-wedge-selftest.sh \
  "ok  AC4 exit 98 (both attempts eventually wedge)" \
  "ok  AC4 first receipt classified sccache-client-orphans" \
  "ok  AC4 no leaked sccache_fixture process remains"
