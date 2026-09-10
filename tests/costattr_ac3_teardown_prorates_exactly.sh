#!/usr/bin/env bash
# costattr_ac3_teardown_prorates_exactly.sh — PRD-build-cost-attribution AC3.
#
# Given a session with rows across 3 slugs, when teardown deletes the box,
# then cost.jsonl gains 3 slug rows whose eur sum equals the session row's
# eur exactly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC3: teardown with 3 attributed slugs still deletes cleanly" \
  "ok  AC3: cost ledger gains 3 slug rows whose eur sums exactly to the session eur"
