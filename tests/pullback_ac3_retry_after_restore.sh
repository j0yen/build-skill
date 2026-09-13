#!/usr/bin/env bash
# pullback_ac3_retry_after_restore.sh — PRD-build-burst-pull-back-restore
# AC3.
#
# Given that same worktree after the floor is restored, When `pull` runs
# again, Then `target/` is present locally, the marker is cleared, and
# `pulled` is printed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullback-ac-common.sh"
pullback_run_suite

fail=0

for line in \
  "ok  pullback AC3: retry after the floor is restored exits 0 and prints pulled" \
  "ok  pullback AC3: retry fetched target/ back" \
  "ok  pullback AC3: retry cleared the dirty marker" \
; do
  if grep -qF "$line" <<<"$PULLBACK_OUT"; then
    echo "$line"
  else
    echo "FAIL pullback AC3: missing/failed: $line" >&2
    fail=1
  fi
done

exit $fail
