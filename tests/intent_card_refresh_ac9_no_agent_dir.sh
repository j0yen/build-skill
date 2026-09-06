#!/usr/bin/env bash
# intent_card_refresh_ac9_no_agent_dir.sh — PRD-build-intent-card-refresh AC9.
#
# Given no agent/ directory in the repo, when the refresh runs, then it
# is created and the card written.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REFRESH="$HERE/../scripts/intent-card-refresh.sh"
FIXTURE="$HERE/fixtures/PRD-fixture-intent-card.md"
JQ="${JQ:-jq}"

[ -x "$REFRESH" ] || { echo "ac9: $REFRESH not executable" >&2; exit 2; }
[ -r "$FIXTURE" ]  || { echo "ac9: $FIXTURE missing" >&2; exit 2; }

repo="$(mktemp -d /tmp/icr-ac9.XXXXXXXX)"
trap 'rm -rf "$repo"' EXIT

fail=0

if [ -e "$repo/agent" ]; then
  echo "FAIL test setup invalid: agent/ already exists" >&2; exit 2
fi

"$REFRESH" "$repo" "$FIXTURE" >/dev/null 2>/tmp/icr-ac9.err
rc=$?
if [ "$rc" != "0" ]; then
  echo "FAIL exit $rc" >&2; cat /tmp/icr-ac9.err >&2; exit 1
fi

if [ -d "$repo/agent" ]; then
  echo "ok  agent/ directory created"
else
  echo "FAIL agent/ directory not created" >&2
  fail=1
fi

card="$repo/agent/intent-card.json"
if [ -f "$card" ] && [ "$("$JQ" -r '.intent_slug' "$card")" = "fixture-intent-card" ]; then
  echo "ok  card written with correct intent_slug"
else
  echo "FAIL card missing or wrong content at $card" >&2
  fail=1
fi

rm -f /tmp/icr-ac9.err
exit $fail
