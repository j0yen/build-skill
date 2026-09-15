#!/usr/bin/env bash
# durheal_ac1_refuse_unreproduced_claim.sh — PRD-build-classification-
# durable-heal AC1.
#
# Given a fixture PRD whose Depends-on file exists (here: a fixture whose
# build_target is valid), When mark-needs-classification.sh is called with
# a reason naming a lint id prd-lint.sh does not currently FAIL on, Then it
# exits 3, journals `needs_classification refused (cause=claim-not-
# reproduced ...)`, and the file and git log are unchanged.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/durheal-ac-common.sh"
run_and_expect_labels "$HERE/../scripts/mark-needs-classification-selftest.sh" \
  "ok  gate-refuse: exits 3" \
  "ok  gate-refuse: prints the refused line" \
  "ok  gate-refuse: journals cause=claim-not-reproduced" \
  "ok  gate-refuse: no new commit" \
  "ok  gate-refuse: file unchanged (still queued)"
