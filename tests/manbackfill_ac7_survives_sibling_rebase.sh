#!/usr/bin/env bash
# manbackfill_ac7_survives_sibling_rebase.sh —
# PRD-build-archive-manifest-backfill AC7 (P1): given the backfill lands
# while a sibling tick commits to the PRDs repo, when both complete, then
# the backfilled line and the flip are in the same commit and survive
# the sibling's `pull --rebase` (fixture proof of lock/commit ordering).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/manbackfill-ac-common.sh"
run_suite_and_expect_labels \
  "ok  MANBACKFILL AC7: archive-commit exits 0" \
  "ok  MANBACKFILL AC7: sibling's commit is present on origin" \
  "ok  MANBACKFILL AC7: our archive commit is present on origin" \
  "ok  MANBACKFILL AC7: backfill + flip survived the rebase" \
  "ok  MANBACKFILL AC7: sibling's pulled-in file is present" \
  "ok  MANBACKFILL AC7: working tree is clean"
