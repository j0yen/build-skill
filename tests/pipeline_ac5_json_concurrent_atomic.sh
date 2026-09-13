#!/usr/bin/env bash
# pipeline_ac5_json_concurrent_atomic.sh — PRD-prd-pipeline-telemetry AC5:
# given --json, when the script runs twice concurrently, then the JSON
# file is whole and parseable after both exit (atomic temp-file rename).
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
printf 'x\n' > "$repo/built-prds/PRD-one.md"
git -C "$repo" add built-prds
GIT_AUTHOR_DATE=2026-09-12T12:00:00Z GIT_COMMITTER_DATE=2026-09-12T12:00:00Z \
  git -C "$repo" commit -q -m "fixture"

stateJ="$tmp/state-json"
mkdir -p "$stateJ"
for _ in 1 2 3 4; do
  BUILD_STATE_DIR="$stateJ" PRD_PIPELINE_PRDS_DIR="$repo" \
    TOKEN_LEDGER_STATE_DIR="$tmp/no-ledger" "$SCRIPT" --date 2026-09-12 --json >/dev/null &
done
wait

out="$stateJ/prd-pipeline/2026-09-12.json"
if [ -f "$out" ] && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$out" 2>/dev/null; then
  echo "ok  AC5: JSON sidecar whole and parseable after 4 concurrent --json runs"
  exit 0
else
  echo "FAIL AC5: JSON sidecar missing or unparseable after concurrent runs"
  exit 1
fi
