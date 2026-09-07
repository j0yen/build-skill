#!/usr/bin/env bash
# intent_card_schema_ac4_malformed_prd_contract.sh —
# PRD-build-intent-card-schema AC4.
#
# Given a malformed PRD (no parseable AC lines), when
# intent-card-refresh.sh runs, then it still exits 3 and writes nothing
# — the existing contract (PRD-build-intent-card-refresh) is unchanged
# by this PRD's sidecar rework. This is a dedicated regression check for
# THIS PRD's edit: the sidecar write (agent/intent-card.carried.json)
# was added near the end of the write path, after the card write; a
# careless edit could have moved the early `die(3, ...)` after some new
# sidecar-related code ran. It didn't — this test proves neither
# agent/intent-card.json NOR agent/intent-card.carried.json exists
# afterward, not just the card alone (intent_card_refresh_ac5_
# malformed_prd.sh, from the sibling PRD, already covers the card half;
# this adds the sidecar half this PRD introduced).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REFRESH="$HERE/../scripts/intent-card-refresh.sh"
FIXTURE="$HERE/fixtures/PRD-fixture-intent-card-malformed.md"

[ -x "$REFRESH" ] || { echo "schema-ac4: $REFRESH not executable" >&2; exit 2; }
[ -r "$FIXTURE" ]  || { echo "schema-ac4: $FIXTURE missing" >&2; exit 2; }

repo="$(mktemp -d /tmp/ics-ac4.XXXXXXXX)"
trap 'rm -rf "$repo"' EXIT

fail=0

err="$("$REFRESH" "$repo" "$FIXTURE" 2>&1 1>/dev/null)"
rc=$?

if [ "$rc" = "3" ]; then
  echo "ok  exit 3"
else
  echo "FAIL exit code: want 3 got $rc" >&2
  fail=1
fi

case "$err" in
  *"$FIXTURE"*)
    echo "ok  stderr names the PRD path" ;;
  *)
    echo "FAIL stderr does not name $FIXTURE" >&2
    fail=1 ;;
esac

if [ -e "$repo/agent" ]; then
  echo "FAIL agent/ dir was created for a malformed PRD" >&2
  fail=1
else
  echo "ok  no agent/ dir created (card and sidecar both absent)"
fi

if [ -e "$repo/agent/intent-card.carried.json" ]; then
  echo "FAIL sidecar written for a malformed PRD" >&2
  fail=1
else
  echo "ok  sidecar not written"
fi

exit $fail
