#!/usr/bin/env bash
# manifest-inv_ac2_needs_classification_lint_pass_heals.sh — PRD-build-
# manifest-invariants AC2.
#
# Given a needs_classification entry whose PRD file passes prd-lint, When
# the reconciler runs, Then the entry is queued and the reason field
# cleared.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MI="$HERE/../scripts/manifest-invariants.sh"
[ -x "$MI" ] || { echo "ac2: $MI not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/manifest-inv-ac2.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state/intent" "$T/build-queue" "$T/built-prds" "$T/parked" "$T/visions"
touch "$T/visions/ac2.md"

cat > "$T/build-queue/PRD-ac2-fixture.md" <<'EOF'
# PRD ac2-fixture
- Status: needs_classification
- build_target: shell
- Vision: visions/ac2.md

## Acceptance criteria

1. P0 — Given X, When Y, Then Z.
EOF

python3 -c "
import json
json.dump({'prds': {'ac2-fixture': {
  'slug': 'ac2-fixture', 'status': 'needs_classification',
  'needs_classification_reason': 'prd-lint: build-target-unknown: was bogus',
  'path': '$T/build-queue/PRD-ac2-fixture.md'
}}}, open('$T/state/manifest.json', 'w'))
"

export BUILD_STATE_DIR="$T/state"
export BUILD_MANIFEST="$T/state/manifest.json"
export LOCK="$T/state/tick.lock"
export JOURNAL="$T/journal.md"
export PATH=/usr/bin:/bin

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# Sanity: the fixture file genuinely passes prd-lint (else this test would
# pass for the wrong reason).
"$HERE/../scripts/prd-lint.sh" "$T/build-queue/PRD-ac2-fixture.md" >/dev/null
expect "fixture PRD passes prd-lint (precondition)" "[ $? -eq 0 ]"

"$MI" --prd-dir "$T"

status="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['ac2-fixture']['status'])")"
expect "entry healed to queued" "[ '$status' = queued ]"

reason="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['ac2-fixture']['needs_classification_reason'])")"
expect "reason field cleared" "[ -z '$reason' ]"

rule="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['ac2-fixture']['invariants_audit_log'][0]['rule'])")"
expect "audit log names the rule" "[ '$rule' = needs-classification-lint-pass ]"

exit $fail
