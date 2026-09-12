#!/usr/bin/env bash
# gatephase_ac5_digest_median_last_per_repo.sh — PRD-build-gate-phase-timing AC5.
#
# Given a journal fixture with four gates for one repo over two days, when
# the digest renders, then it shows one "gate phases (median, last)" line
# for that repo with the correct medians (and a second repo's single gate
# gets its own, unblended line).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatephase-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC5: gate-phase-digest.sh exits 0" \
  "ok  AC5: one 'gate phases (median, last)' line for widget" \
  "ok  AC5: widget ci-checks median/last reads 405/420" \
  "ok  AC5: widget gate median/last reads 1495/1480" \
  "ok  AC5: other repo gets its own line, not blended with widget" \
  "ok  AC5: other ci-checks median/last reads 50/50 (single-gate window)"
