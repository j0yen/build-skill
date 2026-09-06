#!/usr/bin/env bash
# intent_card_refresh_ac1_regen_fields.sh — PRD-build-intent-card-refresh AC1.
#
# Given a landed rust-extend PRD with numbered ACs, when intent-card-
# refresh.sh runs, then agent/intent-card.json carries the PRD's slug,
# source path, and one acceptance_criteria entry per AC line, schema v1
# intact.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REFRESH="$HERE/../scripts/intent-card-refresh.sh"
FIXTURE="$HERE/fixtures/PRD-fixture-intent-card.md"
JQ="${JQ:-jq}"

[ -x "$REFRESH" ] || { echo "ac1: $REFRESH not executable" >&2; exit 2; }
[ -r "$FIXTURE" ]  || { echo "ac1: $FIXTURE missing" >&2; exit 2; }
fixture_abs="$(cd "$(dirname "$FIXTURE")" && pwd)/$(basename "$FIXTURE")"

repo="$(mktemp -d /tmp/icr-ac1.XXXXXXXX)"
trap 'rm -rf "$repo"' EXIT

fail=0
expect() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "ok  $label"
  else
    echo "FAIL $label  want=$want  got=$got" >&2
    fail=1
  fi
}

out="$("$REFRESH" "$repo" "$FIXTURE" 2>/tmp/icr-ac1.err)"
rc=$?
expect "exit 0" "0" "$rc"

card="$repo/agent/intent-card.json"
if [ ! -f "$card" ]; then
  echo "FAIL card not written at $card" >&2
  cat /tmp/icr-ac1.err >&2
  exit 1
fi

expect "schema v1"       "autobuilder.intent_card.v1" "$("$JQ" -r '.schema' "$card")"
expect "intent_slug"     "fixture-intent-card"        "$("$JQ" -r '.intent_slug' "$card")"
expect "prd_source"      "$fixture_abs"               "$("$JQ" -r '.prd_source' "$card")"
expect "ac count"        "2"                          "$("$JQ" '.acceptance_criteria | length' "$card")"
expect "AC1 id"          "AC1"                        "$("$JQ" -r '.acceptance_criteria[0].id' "$card")"
expect "AC1 level"       "MUST"                       "$("$JQ" -r '.acceptance_criteria[0].level' "$card")"
expect "AC2 id"          "AC2"                        "$("$JQ" -r '.acceptance_criteria[1].id' "$card")"
expect "AC2 level"       "SHOULD"                     "$("$JQ" -r '.acceptance_criteria[1].level' "$card")"

rm -f /tmp/icr-ac1.err
exit $fail
