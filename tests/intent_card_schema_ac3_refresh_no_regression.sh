#!/usr/bin/env bash
# intent_card_schema_ac3_refresh_no_regression.sh —
# PRD-build-intent-card-schema AC3 / requirement 7 (P1).
#
# Given a repo whose card is already in the post-migration shape (no
# top-level `carried_forward` key — provenance lives in the sidecar
# agent/intent-card.carried.json), when intent-card-refresh.sh runs
# again, then the refreshed card still has no `carried_forward` key and
# no other key outside intake.rs's `ALLOWED_TOP` allowlist, and the
# sidecar keeps carrying the provenance. This is the regression guard
# requirement 7 asks for: a migrated repo's next refresh must not
# reintroduce the additionalProperties violation that made every real
# card fail `autobuilder intake --validate` before this PRD
# (docs/intent-card-schema.md has the authoritative shape, transcribed
# from intake.rs; this test mirrors it structurally rather than
# shelling out to the Rust binary, so it runs on any node without an
# `autobuilder` install).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REFRESH="$HERE/../scripts/intent-card-refresh.sh"
FIXTURE="$HERE/fixtures/PRD-fixture-intent-card.md"
JQ="${JQ:-jq}"

[ -x "$REFRESH" ] || { echo "schema-ac3: $REFRESH not executable" >&2; exit 2; }
[ -r "$FIXTURE" ]  || { echo "schema-ac3: $FIXTURE missing" >&2; exit 2; }

repo="$(mktemp -d /tmp/ics-ac3.XXXXXXXX)"
trap 'rm -rf "$repo"' EXIT
mkdir -p "$repo/agent"

# A card already in the post-migration shape: no carried_forward key.
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
  "hard_constraints": {"rust_edition": "2021", "target_kind": "cli", "deny_unsafe": true},
  "five_whys_trace": [{"why": 1, "q": "stale?", "a": "yes"}],
  "created_at": "2020-01-01T00:00:00Z"
}
JSON

# Its matching sidecar — every field already migrated, all marked carried.
cat > "$repo/agent/intent-card.carried.json" <<'JSON'
{
  "created_at": true,
  "five_whys_trace": true,
  "hard_constraints": true,
  "non_goals": true,
  "scope": true,
  "unfakeable_metric": true,
  "user_persona": true
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

out="$("$REFRESH" "$repo" "$FIXTURE" 2>/tmp/ics-ac3.err)"
rc=$?
expect "exit 0" "0" "$rc"

card="$repo/agent/intent-card.json"
sidecar="$repo/agent/intent-card.carried.json"

# The regression this PRD exists to prevent: no `carried_forward` key
# reappearing inside the card (intake.rs additionalProperties: false).
expect "card has no carried_forward key" "false" "$("$JQ" -r 'has("carried_forward")' "$card")"

# ALLOWED_TOP from intake.rs, transcribed in docs/intent-card-schema.md.
allowed='["schema","prd_source","root_motivation","user_persona","unfakeable_metric","acceptance_criteria","scope","non_goals","hard_constraints","five_whys_trace","created_at","intent_slug","ambiguities_resolved"]'
extra="$("$JQ" -r --argjson allowed "$allowed" '[keys[] | select(. as $k | ($allowed | index($k)) | not)] | join(",")' "$card")"
expect "no keys outside ALLOWED_TOP" "" "$extra"

# Required fields (REQUIRED from intake.rs) are all still present.
for f in schema prd_source root_motivation user_persona unfakeable_metric \
         acceptance_criteria scope non_goals hard_constraints five_whys_trace created_at; do
  expect "required field present: $f" "true" "$("$JQ" -r --arg f "$f" 'has($f)' "$card")"
done

# Sidecar still carries the provenance (verbatim-shaped: booleans per field).
if [ -f "$sidecar" ]; then
  echo "ok  sidecar still present"
  expect "sidecar user_persona carried" "true" "$("$JQ" -r '.user_persona' "$sidecar")"
else
  echo "FAIL sidecar missing after refresh: $sidecar" >&2
  fail=1
fi

rm -f /tmp/ics-ac3.err
exit $fail
