#!/usr/bin/env bash
# seed-collect_ac6_list_pending_one_line_each.sh — PRD-prd-seed-inbox AC6:
# Given the inbox, When `seed-collect.sh list --pending` runs, Then one
# line per pending seed with date, slug, and source surface.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seed-collect-ac-common.sh"
seed_fixture_setup
trap seed_fixture_teardown EXIT
seed_fixture_two_family_journal

"$SCRIPT" collect >/dev/null 2>&1
lines="$("$SCRIPT" list --pending)"
count=$(echo "$lines" | grep -c .)
assert_eq "$count" "2" "AC6: list --pending prints exactly one line per pending seed"

echo "$lines" | grep -qE '^2026-09-15 2026-09-15-journal-mcphost-ci-checks build-journal:' \
  || fail "AC6: a list line is missing date/slug/source fields"
ok "AC6: each list line carries date, slug, and source surface"
