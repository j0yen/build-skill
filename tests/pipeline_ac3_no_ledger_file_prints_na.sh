#!/usr/bin/env bash
# pipeline_ac3_no_ledger_file_prints_na.sh — PRD-prd-pipeline-telemetry
# AC3: given a date with no token-ledger file, when the script runs, then
# wtok_per_ship prints `na:no-ledger` and exit code is 0.
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
printf 'x\n' > "$repo/built-prds/PRD-solo.md"
git -C "$repo" add built-prds
GIT_AUTHOR_DATE=2026-09-12T12:00:00Z GIT_COMMITTER_DATE=2026-09-12T12:00:00Z \
  git -C "$repo" commit -q -m "fixture"

# $tmp/no-ledger is never created — TOKEN_LEDGER_STATE_DIR/ledger.tsv is
# absent, exercising the "ledger file itself missing" half of AC3.
out="$(PRD_PIPELINE_PRDS_DIR="$repo" TOKEN_LEDGER_STATE_DIR="$tmp/no-ledger" "$SCRIPT" --date 2026-09-12)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'wtok_per_ship=na:no-ledger'; then
  echo "ok  AC3: no-ledger day prints wtok_per_ship=na:no-ledger, exit 0 ($out)"
  exit 0
else
  echo "FAIL AC3: rc=$rc out=$out"
  exit 1
fi
