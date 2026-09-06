#!/usr/bin/env bash
# intent_card_refresh_ac2_carry_forward.sh — PRD-build-intent-card-refresh AC2.
#
# Given fields the PRD cannot source, when the refresh runs against an
# existing card, then those fields carry forward unchanged with
# carried_forward true.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REFRESH="$HERE/../scripts/intent-card-refresh.sh"
FIXTURE="$HERE/fixtures/PRD-fixture-intent-card.md"
JQ="${JQ:-jq}"

[ -x "$REFRESH" ] || { echo "ac2: $REFRESH not executable" >&2; exit 2; }
[ -r "$FIXTURE" ]  || { echo "ac2: $FIXTURE missing" >&2; exit 2; }

repo="$(mktemp -d /tmp/icr-ac2.XXXXXXXX)"
trap 'rm -rf "$repo"' EXIT
mkdir -p "$repo/agent"
cat > "$repo/agent/intent-card.json" <<'JSON'
{
  "schema": "autobuilder.intent_card.v1",
  "prd_source": "some/stale/PRD-old.md",
  "intent_slug": "old-slug",
  "root_motivation": "stale scope",
  "user_persona": "A fleet operator shipping rust-extend PRDs.",
  "unfakeable_metric": {"name": "custom_metric", "lower_is_better": true, "harness_command": "scripts/custom.sh", "target": 5},
  "acceptance_criteria": [],
  "scope": ["stale scope item"],
  "non_goals": ["stale non-goal"],
  "hard_constraints": {"rust_edition": "2021"},
  "five_whys_trace": [{"why": 1, "q": "stale?", "a": "yes"}],
  "created_at": "2020-01-01T00:00:00Z",
  "carried_forward": {}
}
JSON

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

out="$("$REFRESH" "$repo" "$FIXTURE" 2>/tmp/icr-ac2.err)"
rc=$?
expect "exit 0" "0" "$rc"

card="$repo/agent/intent-card.json"
expect "user_persona carried"          "A fleet operator shipping rust-extend PRDs." "$("$JQ" -r '.user_persona' "$card")"
expect "user_persona carried_forward"  "true"   "$("$JQ" -r '.carried_forward.user_persona' "$card")"
expect "unfakeable_metric name kept"   "custom_metric" "$("$JQ" -r '.unfakeable_metric.name' "$card")"
expect "unfakeable_metric carried_forward" "true" "$("$JQ" -r '.carried_forward.unfakeable_metric' "$card")"
expect "scope carried"                 '["stale scope item"]' "$("$JQ" -c '.scope' "$card")"
expect "created_at carried"            "2020-01-01T00:00:00Z" "$("$JQ" -r '.created_at' "$card")"
# Fields the refresh DOES source must not claim carried_forward.
expect "intent_slug updated (not stale)" "fixture-intent-card" "$("$JQ" -r '.intent_slug' "$card")"

rm -f /tmp/icr-ac2.err
exit $fail
