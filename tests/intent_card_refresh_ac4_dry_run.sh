#!/usr/bin/env bash
# intent_card_refresh_ac4_dry_run.sh — PRD-build-intent-card-refresh AC4.
#
# Given --dry-run, when the script runs, then the card content prints
# and no file changes.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REFRESH="$HERE/../scripts/intent-card-refresh.sh"
FIXTURE="$HERE/fixtures/PRD-fixture-intent-card.md"
JQ="${JQ:-jq}"

[ -x "$REFRESH" ] || { echo "ac4: $REFRESH not executable" >&2; exit 2; }
[ -r "$FIXTURE" ]  || { echo "ac4: $FIXTURE missing" >&2; exit 2; }

repo="$(mktemp -d /tmp/icr-ac4.XXXXXXXX)"
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

out="$("$REFRESH" "$repo" "$FIXTURE" --dry-run 2>/tmp/icr-ac4.err)"
rc=$?
expect "exit 0" "0" "$rc"

expect "prints intent_slug" "fixture-intent-card" "$(printf '%s' "$out" | "$JQ" -r '.intent_slug')"

if [ -e "$repo/agent" ]; then
  echo "FAIL agent/ dir was created under --dry-run" >&2
  fail=1
else
  echo "ok  no agent/ dir created"
fi

rm -f /tmp/icr-ac4.err
exit $fail
