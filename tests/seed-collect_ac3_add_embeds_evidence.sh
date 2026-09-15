#!/usr/bin/env bash
# seed-collect_ac3_add_embeds_evidence.sh — PRD-prd-seed-inbox AC3:
# Given `seed-collect.sh add "tenants cannot self-offboard" --evidence
# /tmp/x.txt` where /tmp/x.txt exists, When it runs, Then the seed file
# embeds or copies the evidence and the original path is recorded.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seed-collect-ac-common.sh"
seed_fixture_setup
trap seed_fixture_teardown EXIT

evfile="$SEED_TMPROOT/x.txt"
echo "tenants cannot self-offboard" > "$evfile"

"$SCRIPT" add "tenants cannot self-offboard" --evidence "$evfile" >/dev/null 2>&1

seedfile="$(grep -rl "tenants cannot self-offboard" "$SEED_PRD_DIR"/seeds/*.md | head -1)"
[ -n "$seedfile" ] || fail "AC3: no seed file was written for the manual observation"
ok "AC3: a seed file was written for the manual observation"

grep -qF -- "$evfile" "$seedfile" || fail "AC3: original evidence path is not recorded in the seed file"
ok "AC3: the original evidence path is recorded in the seed file"

copied="$(grep -oE 'seeds/evidence/[^`]+' "$seedfile" | head -1)"
[ -n "$copied" ] || fail "AC3: no copied-evidence pointer found in the seed file"
[ -f "$SEED_PRD_DIR/$copied" ] || fail "AC3: copied evidence file $copied does not exist"
ok "AC3: the evidence file was copied into seeds/evidence/ alongside the original path"
