#!/usr/bin/env bash
# manbackfill_ac3_existing_line_flipped_not_backfilled.sh —
# PRD-build-archive-manifest-backfill AC3: given a fixture MANIFEST.md
# with an existing line for the slug, when archive-commit.sh runs, then
# no backfill occurs, the line is flipped as today, and no
# `manifest-backfill` line is journaled. The required happy-path
# regression case proving the new backfill code path never fires when
# it shouldn't.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/manbackfill-ac-common.sh"
run_suite_and_expect_labels \
  "ok  MANBACKFILL AC3: archive-commit exits 0" \
  "ok  MANBACKFILL AC3: existing line flipped to shipped" \
  "ok  MANBACKFILL AC3: exactly one line for the slug (no dup appended)" \
  "ok  MANBACKFILL AC3: no manifest-backfill line journaled" \
  "ok  MANBACKFILL AC3: commit message has no backfill note"
