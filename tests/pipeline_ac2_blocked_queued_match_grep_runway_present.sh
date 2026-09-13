#!/usr/bin/env bash
# pipeline_ac2_blocked_queued_match_grep_runway_present.sh —
# PRD-prd-pipeline-telemetry AC2: given today's live repo (a fixture repo
# here, so this is deterministic on rerun), when the script runs with no
# flags, then queued and blocked counts match `grep -c` over build-queue
# frontmatter and the line includes runway_h.
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
printf '%s\n' "- Status: queued"  > "$repo/build-queue/PRD-gamma.md"
printf '%s\n' "- Status: blocked" > "$repo/build-queue/PRD-beta.md"
printf '%s\n' "- Status: building" > "$repo/build-queue/PRD-delta.md"
git -C "$repo" add build-queue
GIT_AUTHOR_DATE=2026-09-12T12:00:00Z GIT_COMMITTER_DATE=2026-09-12T12:00:00Z \
  git -C "$repo" commit -q -m "fixture"

grep_blocked="$(grep -lE '^- Status: blocked' "$repo"/build-queue/PRD-*.md | wc -l | tr -d '[:space:]')"
grep_queued="$(grep -lE '^- Status: queued'  "$repo"/build-queue/PRD-*.md | wc -l | tr -d '[:space:]')"

out="$(PRD_PIPELINE_PRDS_DIR="$repo" TOKEN_LEDGER_STATE_DIR="$tmp/no-ledger" "$SCRIPT")"
script_blocked="$(printf '%s' "$out" | grep -oE 'blocked=[0-9]+' | cut -d= -f2)"
script_queued="$(printf '%s' "$out" | grep -oE 'queued=[0-9]+' | cut -d= -f2)"

fails=0
if [ "$script_blocked" = "$grep_blocked" ] && [ "$script_queued" = "$grep_queued" ]; then
  echo "ok  AC2: blocked=$script_blocked queued=$script_queued match grep -c ground truth"
else
  echo "FAIL AC2: blocked=$script_blocked (want $grep_blocked) queued=$script_queued (want $grep_queued)"
  fails=1
fi
case "$out" in
  *"runway_h="*) echo "ok  AC2: line includes runway_h" ;;
  *) echo "FAIL AC2: no runway_h field in: $out"; fails=1 ;;
esac
exit "$fails"
