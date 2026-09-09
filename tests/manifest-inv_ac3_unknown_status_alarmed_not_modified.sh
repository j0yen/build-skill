#!/usr/bin/env bash
# manifest-inv_ac3_unknown_status_alarmed_not_modified.sh — PRD-build-
# manifest-invariants AC3.
#
# Given an entry with an unknown status string, When the reconciler runs,
# Then it is NOT modified and an alarm line lands in the journal (and
# docket when present — here docket is deliberately absent from PATH, so
# this also exercises the fail-open half of requirement 3).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MI="$HERE/../scripts/manifest-invariants.sh"
[ -x "$MI" ] || { echo "ac3: $MI not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/manifest-inv-ac3.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state/intent" "$T/build-queue" "$T/built-prds" "$T/parked"

python3 -c "
import json
json.dump({'prds': {'ac3-fixture': {
  'slug': 'ac3-fixture', 'status': 'totally-bogus-status', 'foo': 'bar'
}}}, open('$T/state/manifest.json', 'w'))
"
before_hash="$(sha256sum "$T/state/manifest.json" | awk '{print $1}')"

export BUILD_STATE_DIR="$T/state"
export BUILD_MANIFEST="$T/state/manifest.json"
export LOCK="$T/state/tick.lock"
export JOURNAL="$T/journal.md"
export PATH=/usr/bin:/bin   # docket absent — exercises fail-open explicitly

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

"$MI" --prd-dir "$T"

after_hash="$(sha256sum "$T/state/manifest.json" | awk '{print $1}')"
expect "entry not modified (manifest byte-unchanged)" "[ '$before_hash' = '$after_hash' ]"

status="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['ac3-fixture']['status'])")"
expect "status still the unknown value" "[ '$status' = totally-bogus-status ]"

expect "journal has an alarm line for this slug"      "grep -q 'ac3-fixture.*alarm' '$T/journal.md'"
expect "alarm class is unknown-status"                "grep -q 'class=unknown-status' '$T/journal.md'"
expect "no invariants_audit_log was fabricated" \
  "[ \"\$(python3 -c \"import json; print('invariants_audit_log' in json.load(open('$T/state/manifest.json'))['prds']['ac3-fixture'])\")\" = False ]"

exit $fail
