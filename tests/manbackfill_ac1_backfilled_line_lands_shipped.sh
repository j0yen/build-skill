#!/usr/bin/env bash
# manbackfill_ac1_backfilled_line_lands_shipped.sh —
# PRD-build-archive-manifest-backfill AC1: given a fixture PRDs checkout
# whose MANIFEST.md has no line for the slug, when archive-commit.sh
# runs, then a line is appended in the shipped (built-prds) section,
# flipped to shipped, the archive completes with rc=0, and the journal
# contains `manifest-backfill (slug=… section=…)`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/manbackfill-ac-common.sh"
run_suite_and_expect_labels \
  "ok  MANBACKFILL AC1: archive-commit exits 0" \
  "ok  MANBACKFILL AC1: build-queue/PRD-mbfill1.md is gone" \
  "ok  MANBACKFILL AC1: built-prds/PRD-mbfill1.md exists" \
  "ok  MANBACKFILL AC1: a shipped line now exists for mbfill1" \
  "ok  MANBACKFILL AC1: backfilled line lands in built-prds section" \
  "ok  MANBACKFILL AC1: journal names the backfill"
