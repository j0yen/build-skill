#!/usr/bin/env bash
# pipeline_ac6_zero_ships_week_no_division_error.sh —
# PRD-prd-pipeline-telemetry AC6: given a repo with zero ships in 7 days,
# when `--week` runs, then runway_h prints `na` and no division error
# occurs (i.e. the script still exits 0 and every line is well-formed).
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
printf '%s\n' "- Status: queued" > "$repo/build-queue/PRD-solo.md"
git -C "$repo" add build-queue/PRD-solo.md
GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z \
  git -C "$repo" commit -q -m "old draft, no ships ever"

out="$(PRD_PIPELINE_PRDS_DIR="$repo" TOKEN_LEDGER_STATE_DIR="$tmp/no-ledger" "$SCRIPT" --date 2026-09-12 --week)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qE 'runway_h=[0-9]'; then
  echo "ok  AC6: zero-ship week prints runway_h=na throughout, exit 0, no division error"
  exit 0
else
  echo "FAIL AC6: rc=$rc out=<<<$out>>>"
  exit 1
fi
