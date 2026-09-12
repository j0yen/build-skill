#!/usr/bin/env bash
# archatomic_ac4_lock_timeout_no_writes.sh —
# PRD-build-archive-atomic-commit AC4: given the lock held for longer
# than the bound (fixture bound 2s), when archive-commit.sh runs, then it
# exits non-zero with `lock-timeout` and no writes. A second required
# real failure-mode selftest case.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/archatomic-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC4: exits non-zero" \
  "ok  AC4: names lock-timeout" \
  "ok  AC4: no writes (HEAD unchanged)" \
  "ok  AC4: working tree clean" \
  "ok  AC4: PRD still queued"
