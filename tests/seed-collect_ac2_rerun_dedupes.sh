#!/usr/bin/env bash
# seed-collect_ac2_rerun_dedupes.sh — PRD-prd-seed-inbox AC2:
# Given the same journal, When collect runs again, Then no new files
# appear (dedupe proven by file count and git status).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seed-collect-ac-common.sh"
seed_fixture_setup
trap seed_fixture_teardown EXIT
seed_fixture_two_family_journal

"$SCRIPT" collect >/dev/null 2>&1
before=$(find "$SEED_PRD_DIR/seeds" -maxdepth 1 -name '*.md' | wc -l)

out2="$("$SCRIPT" collect 2>&1)"
after=$(find "$SEED_PRD_DIR/seeds" -maxdepth 1 -name '*.md' | wc -l)
assert_eq "$after" "$before" "AC2: file count unchanged after rerun"

status="$(git -C "$SEED_PRD_DIR" status --porcelain)"
[ -z "$status" ] || fail "AC2: git status not clean after rerun ($status)"
ok "AC2: git status is clean after rerun (no new/uncommitted seed files)"

echo "$out2" | grep -q "dedupe skip" || fail "AC2: rerun did not log a dedupe skip"
ok "AC2: rerun logs a dedupe skip for the previously-seen fingerprint"
