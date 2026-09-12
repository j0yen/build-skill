#!/usr/bin/env bash
# unitlive_ac3_digest_two_consecutive.sh — PRD-buildloop-unit-liveness AC3.
#
# Given a unit reported inactive on two consecutive runs, when the digest
# fixture is rendered, then it contains the `LIVENESS WARN` naming that
# unit and the first-seen time; after one run of inactive only, it
# contains none.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/unitlive-ac-common.sh"
run_unitlive_suite_and_expect_labels \
  "ok  unitlive_ac3a: after one inactive run, digest is empty" \
  "ok  unitlive_ac3b: after two consecutive inactive runs, digest names unit + first-seen time"
