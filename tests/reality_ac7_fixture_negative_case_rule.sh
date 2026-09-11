#!/usr/bin/env bash
# reality_ac7_fixture_negative_case_rule.sh —
# PRD-build-post-ship-reality-check AC7.
#
# Given a shipped fixture diff that adds a new subcommand with only a
# success case, When the archive step runs, Then it blocks with
# `fixture-negative-case-missing: <subcommand>`. Also covers `prd-lint.sh`
# warning `selftest-no-negative-case` on a happy-path-only AC mention.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reality AC7: prd-lint warns selftest-no-negative-case on a happy-path-only mention" \
  "ok  reality AC7: verified-completed --check-fixture-negative-case blocks a success-only diff"
