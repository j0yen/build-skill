#!/usr/bin/env bash
# manbackfill_ac4_duplicate_lines_refuse.sh —
# PRD-build-archive-manifest-backfill AC4: given a fixture MANIFEST.md
# containing two conflicting lines for the same slug, when
# archive-commit.sh runs, then it dies with a distinct exit code (not 4)
# and a message naming the duplicate. One of the repo's two required
# real failure-mode selftest cases for this PRD (real corruption, not
# mere absence).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/manbackfill-ac-common.sh"
run_suite_and_expect_labels \
  "ok  MANBACKFILL AC4: exits non-zero" \
  "ok  MANBACKFILL AC4: exit code is distinct from 4" \
  "ok  MANBACKFILL AC4: names the duplicate" \
  "ok  MANBACKFILL AC4: no writes (HEAD unchanged)" \
  "ok  MANBACKFILL AC4: working tree clean" \
  "ok  MANBACKFILL AC4: PRD still queued (untouched)"
