#!/usr/bin/env bash
# archatomic_ac2_missing_receipt_refuses.sh —
# PRD-build-archive-atomic-commit AC2: given the same fixture with the
# fake receipt missing, when the script runs, then it exits non-zero
# naming the `receipt` step, the working tree is unchanged, and origin
# has no new commit. This is one of the repo's required real
# failure-mode selftest cases (not just a success-path assertion).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/archatomic-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC2: exits non-zero" \
  "ok  AC2: names the receipt step" \
  "ok  AC2: working tree unchanged" \
  "ok  AC2: no new local commit" \
  "ok  AC2: origin got no new commit" \
  "ok  AC2: PRD still queued (untouched)"
