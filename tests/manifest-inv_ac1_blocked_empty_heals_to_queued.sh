#!/usr/bin/env bash
# manifest-inv_ac1_blocked_empty_heals_to_queued.sh — PRD-build-manifest-
# invariants AC1.
#
# Given a fixture manifest with blocked+empty-blockers+empty-iter_log, When
# the reconciler runs, Then the entry is queued with an invariants_audit_log
# record naming the rule.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MI="$HERE/../scripts/manifest-invariants.sh"
[ -x "$MI" ] || { echo "ac1: $MI not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/manifest-inv-ac1.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state/intent" "$T/build-queue" "$T/built-prds" "$T/parked"

cat > "$T/build-queue/PRD-ac1-fixture.md" <<'EOF'
# PRD ac1-fixture
- Status: blocked
- build_target: shell
EOF

python3 -c "
import json
json.dump({'prds': {'ac1-fixture': {
  'slug': 'ac1-fixture', 'status': 'blocked', 'blockers': [], 'iter_log': [],
  'path': '$T/build-queue/PRD-ac1-fixture.md'
}}}, open('$T/state/manifest.json', 'w'))
"

export BUILD_STATE_DIR="$T/state"
export BUILD_MANIFEST="$T/state/manifest.json"
export LOCK="$T/state/tick.lock"
export JOURNAL="$T/journal.md"
export PATH=/usr/bin:/bin   # no docket on this PATH — never touch the real ledger

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

"$MI" --prd-dir "$T"

status="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['ac1-fixture']['status'])")"
expect "entry healed to queued" "[ '$status' = queued ]"

rule="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['ac1-fixture']['invariants_audit_log'][0]['rule'])")"
expect "audit log names the rule" "[ '$rule' = blocked-empty-blockers-empty-iterlog ]"

expect "journal line records the heal" "grep -q 'ac1-fixture.*heal' '$T/journal.md'"

exit $fail
