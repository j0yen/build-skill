#!/usr/bin/env bash
# manbackfill_ac2_format_matches_sibling.sh —
# PRD-build-archive-manifest-backfill AC2: given that same run, when the
# resulting MANIFEST.md line is compared against the format of a sibling
# entry in the file, then it matches that format (same field order and
# separators) and the commit message names the backfill.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/manbackfill-ac-common.sh"
run_suite_and_expect_labels \
  "ok  MANBACKFILL AC2: backfilled line matches sibling's exact format" \
  "ok  MANBACKFILL AC2: commit message names the backfill" \
  "ok  MANBACKFILL AC2: commit subject is unchanged by the backfill note"
