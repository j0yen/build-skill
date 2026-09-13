#!/usr/bin/env bash
# pipeline_ac1_drafted_shipped_match_gitlog.sh —
# PRD-prd-pipeline-telemetry AC1: given the PRDs repo at a sha with known
# history, when `prd-pipeline.sh --date 2026-09-12` runs, then the printed
# drafted/shipped counts equal the git-log ground truth for that day
# (fixture-pinned, self-contained — builds its own tiny repo).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/prd-pipeline.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/prds"
mkdir -p "$repo/build-queue" "$repo/built-prds"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name "Test"

# 2026-09-10: two drafts, out of the pinned day's scope.
printf '%s\n' "- Status: queued" > "$repo/build-queue/PRD-alpha.md"
printf '%s\n' "- Status: queued" > "$repo/build-queue/PRD-beta.md"
git -C "$repo" add build-queue/PRD-alpha.md build-queue/PRD-beta.md
GIT_AUTHOR_DATE=2026-09-10T12:00:00Z GIT_COMMITTER_DATE=2026-09-10T12:00:00Z \
  git -C "$repo" commit -q -m "fixture 2026-09-10"

# 2026-09-12 (the pinned date): one more draft, one ship (git mv, counts
# as an add at the new path with the default --no-renames diff).
printf '%s\n' "- Status: queued" > "$repo/build-queue/PRD-gamma.md"
git -C "$repo" add build-queue/PRD-gamma.md
git -C "$repo" mv build-queue/PRD-alpha.md built-prds/PRD-alpha.md
GIT_AUTHOR_DATE=2026-09-12T12:00:00Z GIT_COMMITTER_DATE=2026-09-12T12:00:00Z \
  git -C "$repo" commit -q -m "fixture 2026-09-12"

out="$(PRD_PIPELINE_PRDS_DIR="$repo" TOKEN_LEDGER_STATE_DIR="$tmp/no-ledger" "$SCRIPT" --date 2026-09-12)"
case "$out" in
  "2026-09-12 drafted=1 shipped=1 "*)
    echo "ok  AC1: drafted=1 shipped=1 for 2026-09-12 matches git-log ground truth ($out)"
    exit 0
    ;;
  *)
    echo "FAIL AC1: expected drafted=1 shipped=1, got: $out"
    exit 1
    ;;
esac
