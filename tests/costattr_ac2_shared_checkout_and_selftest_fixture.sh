#!/usr/bin/env bash
# costattr_ac2_shared_checkout_and_selftest_fixture.sh — PRD-build-cost-attribution AC2.
#
# Given runs from the shared checkout and a gb-ac fixture, when attributed,
# then slugs are shared-mcphost and selftest respectively; nothing is dropped.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC2: the shared checkout itself is attributed shared-mcphost" \
  "ok  AC2: a gb-ac fixture path is attributed selftest" \
  "ok  AC2: nothing dropped — both runs landed a row (2 total)"
