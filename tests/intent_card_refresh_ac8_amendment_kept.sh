#!/usr/bin/env bash
# intent_card_refresh_ac8_amendment_kept.sh — PRD-build-intent-card-
# refresh AC8 (P1).
#
# Given an amendment request with additions NOT covered, when the
# refresh runs, then the amendment file is left in place.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REFRESH="$HERE/../scripts/intent-card-refresh.sh"
FIXTURE="$HERE/fixtures/PRD-fixture-intent-card.md"
JQ="${JQ:-jq}"

[ -x "$REFRESH" ] || { echo "ac8: $REFRESH not executable" >&2; exit 2; }
[ -r "$FIXTURE" ]  || { echo "ac8: $FIXTURE missing" >&2; exit 2; }

repo="$(mktemp -d /tmp/icr-ac8.XXXXXXXX)"
trap 'rm -rf "$repo"' EXIT
mkdir -p "$repo/agent"
amendment="$repo/agent/intent_card_amendment_request.json"
"$JQ" -n '{scope_additions: [{prd_source: "/some/other/PRD-unrelated-hotfix.md", note: "not covered by this run"}]}' \
  > "$amendment"
before_sum="$(md5sum "$amendment" | awk '{print $1}')"

fail=0

out="$("$REFRESH" "$repo" "$FIXTURE" 2>/tmp/icr-ac8.err)"
rc=$?
if [ "$rc" != "0" ]; then
  echo "FAIL exit $rc" >&2; cat /tmp/icr-ac8.err >&2; exit 1
fi

if [ ! -f "$amendment" ]; then
  echo "FAIL amendment file was removed despite an uncovered entry" >&2
  fail=1
else
  after_sum="$(md5sum "$amendment" | awk '{print $1}')"
  if [ "$before_sum" = "$after_sum" ]; then
    echo "ok  amendment file left in place untouched"
  else
    echo "FAIL amendment file present but modified" >&2
    fail=1
  fi
fi

got="$(printf '%s' "$out" | "$JQ" -r '.amendment_removed')"
if [ "$got" = "false" ]; then
  echo "ok  amendment_removed:false in run summary"
else
  echo "FAIL amendment_removed want=false got=$got" >&2
  fail=1
fi

rm -f /tmp/icr-ac8.err
exit $fail
