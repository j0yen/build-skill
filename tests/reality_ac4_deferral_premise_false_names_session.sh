#!/usr/bin/env bash
# reality_ac4_deferral_premise_false_names_session.sh —
# PRD-build-post-ship-reality-check AC4.
#
# Given a PRD with `deferred_acs: [4]` justified as "box unreachable" and a
# fake lane reporting an active session, When the archive step runs, Then
# it exits non-zero with `deferral-premise-false: AC4` naming the session
# id. Also covers the true-premise case (a genuinely unreachable box)
# exiting 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reality AC4: deferral-premise-false exits 1" \
  "ok  reality AC4: names AC4 and the session id" \
  "ok  reality AC4 (true premise): a genuinely unreachable box exits 0"
