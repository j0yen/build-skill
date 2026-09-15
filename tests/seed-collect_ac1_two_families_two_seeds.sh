#!/usr/bin/env bash
# seed-collect_ac1_two_families_two_seeds.sh — PRD-prd-seed-inbox AC1:
# Given a build journal with two digest failure families, When collect
# runs, Then two pending seed files exist with source paths and inline
# evidence excerpts.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seed-collect-ac-common.sh"
seed_fixture_setup
trap seed_fixture_teardown EXIT
seed_fixture_two_family_journal

"$SCRIPT" collect >/dev/null 2>&1

count=$(find "$SEED_PRD_DIR/seeds" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
assert_eq "$count" "2" "AC1: exactly two pending seed files exist"

for f in "$SEED_PRD_DIR"/seeds/*.md; do
  grep -q '^- Status: pending$' "$f" || fail "AC1: $f missing Status: pending"
  grep -q '^- Source: build-journal:' "$f" || fail "AC1: $f missing a build-journal Source: path"
  grep -qF '```' "$f" || fail "AC1: $f missing an inline evidence excerpt"
done
ok "AC1: every seed file carries Status: pending, a Source: path, and an inline evidence excerpt"
