#!/usr/bin/env bash
# intent_card_refresh_ac3_idempotent.sh — PRD-build-intent-card-refresh AC3.
#
# Given the same repo and PRD, when the script runs twice, then the
# second run produces a byte-identical card. (Manually re-verified
# against wintermute/keel per the PRD's blocked-status note; this
# automates that check against a hermetic fixture repo.)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REFRESH="$HERE/../scripts/intent-card-refresh.sh"
FIXTURE="$HERE/fixtures/PRD-fixture-intent-card.md"

[ -x "$REFRESH" ] || { echo "ac3: $REFRESH not executable" >&2; exit 2; }
[ -r "$FIXTURE" ]  || { echo "ac3: $FIXTURE missing" >&2; exit 2; }

repo="$(mktemp -d /tmp/icr-ac3.XXXXXXXX)"
trap 'rm -rf "$repo"' EXIT

fail=0

"$REFRESH" "$repo" "$FIXTURE" >/dev/null 2>/tmp/icr-ac3.err || { echo "FAIL first run failed" >&2; cat /tmp/icr-ac3.err >&2; exit 1; }
card="$repo/agent/intent-card.json"
sum1="$(md5sum "$card" | awk '{print $1}')"

"$REFRESH" "$repo" "$FIXTURE" >/dev/null 2>>/tmp/icr-ac3.err || { echo "FAIL second run failed" >&2; cat /tmp/icr-ac3.err >&2; exit 1; }
sum2="$(md5sum "$card" | awk '{print $1}')"

if [ "$sum1" = "$sum2" ]; then
  echo "ok  second run byte-identical to first ($sum1)"
else
  echo "FAIL card changed between runs: $sum1 -> $sum2" >&2
  fail=1
fi

rm -f /tmp/icr-ac3.err
exit $fail
