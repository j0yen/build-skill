#!/usr/bin/env bash
# manbackfill_ac5_unreadable_manifest_dies.sh —
# PRD-build-archive-manifest-backfill AC5: given an unreadable
# MANIFEST.md, when archive-commit.sh runs, then it dies with exit 4 as
# today. The second of the repo's two required real failure-mode
# selftest cases for this PRD — proves the backfill feature never
# swallows real corruption/unreadability under the same exit code used
# for mere absence.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/manbackfill-ac-common.sh"
run_suite_and_expect_labels \
  "ok  MANBACKFILL AC5: exits with code 4" \
  "ok  MANBACKFILL AC5: PRD still queued (untouched)"
