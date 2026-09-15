#!/usr/bin/env bash
# intent_card_refresh_ac11_extended_gates_sync.sh — PRD-mcphost-gate-debt-c627803
# (build-skill side of the fix): the recurring "fix gate paper trail" debt
# (mcphost commits 6e17b89, 24d1794, et al.) happened because
# intent-card-refresh.sh regenerated agent/intent-card.json on every ship
# but never touched <repo>/extended-gates.toml's prd_path, so CI's
# ac01_extended_gates_prd_path_resolves_and_matches_card went red on main
# after every landing whose card repointed at a new PRD.
#
# Given a repo whose extended-gates.toml names a stale PRD (with a stale
# repo-root copy of that PRD), when intent-card-refresh.sh runs against a
# newly-landed PRD, then extended-gates.toml's prd_path is rewritten to
# that PRD's basename, a fresh repo-root copy of it exists, the stale copy
# is removed, and a second run is a no-op (idempotent).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REFRESH="$HERE/../scripts/intent-card-refresh.sh"
FIXTURE="$HERE/fixtures/PRD-fixture-intent-card.md"

[ -x "$REFRESH" ] || { echo "ac11: $REFRESH not executable" >&2; exit 2; }
[ -r "$FIXTURE" ]  || { echo "ac11: $FIXTURE missing" >&2; exit 2; }

repo="$(mktemp -d /tmp/icr-ac11.XXXXXXXX)"
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

stale_name="PRD-fixture-intent-card-STALE.md"
echo "# stale fixture PRD, not the one landing" > "$repo/$stale_name"
cat > "$repo/extended-gates.toml" <<TOML
# Config for the rustbuild extended-gates producers (Stage 4).
prd_path = "$stale_name"
mutation_kill_min_pct = 50.0
TOML

out="$("$REFRESH" "$repo" "$FIXTURE" 2>/tmp/icr-ac11.err)"
rc=$?
expect "exit 0" "0" "$rc"
[ "$rc" -eq 0 ] || { cat /tmp/icr-ac11.err >&2; exit 1; }

new_name="$(basename "$FIXTURE")"
gates="$repo/extended-gates.toml"

expect "prd_path rewritten"    "prd_path = \"$new_name\""  "$(grep '^prd_path' "$gates")"
expect "mutation key preserved" "mutation_kill_min_pct = 50.0" "$(grep '^mutation_kill_min_pct' "$gates")"
expect "new copy is a file"    "yes" "$([ -f "$repo/$new_name" ] && echo yes || echo no)"
expect "stale copy removed"   "yes" "$([ ! -f "$repo/$stale_name" ] && echo yes || echo no)"

before="$(cat "$gates")"
out2="$("$REFRESH" "$repo" "$FIXTURE" 2>/tmp/icr-ac11.err2)"
rc2=$?
expect "second run exit 0" "0" "$rc2"
after="$(cat "$gates")"
expect "idempotent (no further edit)" "$before" "$after"

rm -f /tmp/icr-ac11.err /tmp/icr-ac11.err2
exit $fail
