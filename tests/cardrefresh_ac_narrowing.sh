#!/usr/bin/env bash
# cardrefresh_ac_narrowing.sh — fix for intent-card-refresh.sh's
# acceptance_criteria narrowing gap (2026-09-17 hand-fix, decision
# 197422c7): scope/non_goals/five_whys_trace already never widen past
# an existing card (see carry() in intent-card-refresh.sh), but
# acceptance_criteria re-parses every numbered AC line in the PRD
# passed to the refresh and, for any AC not explicitly mapped in
# agent/test-map.json's ac_test_map, fell back to the scaffold-
# convention path (tests/acceptance_ac<n>.rs) UNCONDITIONALLY -- even
# when that repo already curates a test_map and the file does not
# exist. Two real hits, 2026-09-17: mcphost-stdlib-pseudo-modules
# picked up sibling mcphost-proof-lane-loop-config's AC1-4 pointers;
# build-land-conflict-resolver pointed at nonexistent
# tests/acceptance_ac{8,9,10,11}.rs, both deterministic flake-audit
# failures.
#
# Fixture: a temp repo shared by two PRDs (A and B) with a curated,
# non-empty agent/test-map.json that maps only B's own two real ACs
# (AC1, AC2) to real files this tree actually has. PRD B's own
# document additionally numbers AC3/AC4 -- reusing sibling PRD A's own
# AC numbers in this shared build_into repo's PRD-numbering scheme --
# with no mapping and no scaffold file for either in B's tree. Running
# the refresh for PRD B must emit AC1/AC2 (real, mapped) and MUST NOT
# emit AC3/AC4 (inherited, would point at files the tree does not
# have). Must fail on the pre-fix script (AC3/AC4 always fell back to
# the unconditional scaffold path) and pass on the fixed one.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REFRESH="$HERE/../scripts/intent-card-refresh.sh"
FIXTURE_B="$HERE/fixtures/PRD-fixture-cardrefresh-narrowing-b.md"
JQ="${JQ:-jq}"

[ -x "$REFRESH" ]   || { echo "cardrefresh_ac_narrowing: $REFRESH not executable" >&2; exit 2; }
[ -r "$FIXTURE_B" ] || { echo "cardrefresh_ac_narrowing: $FIXTURE_B missing" >&2; exit 2; }

repo="$(mktemp -d /tmp/icr-narrow.XXXXXXXX)"
trap 'rm -rf "$repo"' EXIT

# Shared build_into layout: both PRDs' source docs live under the same
# repo's prds/ dir (not read by the refresh directly -- it only takes
# one prd_path at a time -- but present so the fixture actually looks
# like the shared-repo scenario the defect names).
mkdir -p "$repo/prds/build-queue"
cp "$HERE/fixtures/PRD-fixture-cardrefresh-narrowing-a.md" "$repo/prds/build-queue/"
cp "$FIXTURE_B" "$repo/prds/build-queue/"

# B's own real, already-built tests -- these exist in the tree.
mkdir -p "$repo/tests"
echo '// AC1 real test' > "$repo/tests/ac1_real.rs"
echo '// AC2 real test' > "$repo/tests/ac2_real.rs"
# Deliberately NOT created: tests/acceptance_ac3.rs, acceptance_ac4.rs
# -- AC3/AC4 belong to sibling PRD A, not to B.

mkdir -p "$repo/agent"
cat > "$repo/agent/test-map.json" <<'JSON'
{
  "ac_test_map": {
    "AC1": "tests/ac1_real.rs",
    "AC2": "tests/ac2_real.rs"
  }
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

out="$("$REFRESH" "$repo" "$repo/prds/build-queue/$(basename "$FIXTURE_B")" 2>/tmp/icr-narrow.err)"
rc=$?
expect "exit 0" "0" "$rc"

card="$repo/agent/intent-card.json"
if [ ! -f "$card" ]; then
  echo "FAIL card not written at $card" >&2
  cat /tmp/icr-narrow.err >&2
  exit 1
fi

ac_ids="$("$JQ" -c '[.acceptance_criteria[].id]' "$card")"
echo "  acceptance_criteria ids: $ac_ids"

expect "ac count is 2 (only B's own ACs)" "2" "$("$JQ" '.acceptance_criteria | length' "$card")"
expect "AC1 kept, mapped to its real test" \
  "tests/ac1_real.rs" "$("$JQ" -r '.acceptance_criteria[] | select(.id=="AC1") | .test' "$card")"
expect "AC2 kept, mapped to its real test" \
  "tests/ac2_real.rs" "$("$JQ" -r '.acceptance_criteria[] | select(.id=="AC2") | .test' "$card")"
expect "AC3 (sibling-inherited) dropped, not present" \
  "" "$("$JQ" -r '.acceptance_criteria[] | select(.id=="AC3") | .id' "$card")"
expect "AC4 (sibling-inherited) dropped, not present" \
  "" "$("$JQ" -r '.acceptance_criteria[] | select(.id=="AC4") | .id' "$card")"
expect "no pointer to a nonexistent tests/acceptance_ac*.rs in the card" \
  "" "$("$JQ" -r '.acceptance_criteria[].test' "$card" | grep -E '^tests/acceptance_ac(3|4)\.rs$')"

rm -f /tmp/icr-narrow.err
exit $fail
