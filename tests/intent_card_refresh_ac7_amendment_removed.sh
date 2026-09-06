#!/usr/bin/env bash
# intent_card_refresh_ac7_amendment_removed.sh — PRD-build-intent-card-
# refresh AC7 (P1).
#
# Given an amendment request whose additions are covered by the
# refreshed card, when the refresh runs, then the amendment file is
# removed in the same commit (pass — same run here, since this is a
# script-level test, not a git one).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REFRESH="$HERE/../scripts/intent-card-refresh.sh"
FIXTURE="$HERE/fixtures/PRD-fixture-intent-card.md"
JQ="${JQ:-jq}"

[ -x "$REFRESH" ] || { echo "ac7: $REFRESH not executable" >&2; exit 2; }
[ -r "$FIXTURE" ]  || { echo "ac7: $FIXTURE missing" >&2; exit 2; }
fixture_abs="$(cd "$(dirname "$FIXTURE")" && pwd)/$(basename "$FIXTURE")"

repo="$(mktemp -d /tmp/icr-ac7.XXXXXXXX)"
trap 'rm -rf "$repo"' EXIT
mkdir -p "$repo/agent"
amendment="$repo/agent/intent_card_amendment_request.json"
"$JQ" -n --arg prd "$fixture_abs" \
  '{scope_additions: [{prd_source: $prd, note: "covered by this run"}, {note: "bare non-PRD note"}]}' \
  > "$amendment"

fail=0

out="$("$REFRESH" "$repo" "$FIXTURE" 2>/tmp/icr-ac7.err)"
rc=$?
if [ "$rc" != "0" ]; then
  echo "FAIL exit $rc" >&2; cat /tmp/icr-ac7.err >&2; exit 1
fi

if [ -f "$amendment" ]; then
  echo "FAIL amendment file still present after a fully-covered run" >&2
  fail=1
else
  echo "ok  amendment file removed"
fi

got="$(printf '%s' "$out" | "$JQ" -r '.amendment_removed')"
if [ "$got" = "true" ]; then
  echo "ok  amendment_removed:true in run summary"
else
  echo "FAIL amendment_removed want=true got=$got" >&2
  fail=1
fi

rm -f /tmp/icr-ac7.err
exit $fail
