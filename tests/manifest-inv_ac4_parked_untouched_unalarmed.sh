#!/usr/bin/env bash
# manifest-inv_ac4_parked_untouched_unalarmed.sh — PRD-build-manifest-
# invariants AC4.
#
# Given a parked entry violating any rule (here: blocked-shaped emptiness
# AND an unknown-status-shaped condition would both apply if this entry
# weren't parked), When the reconciler runs, Then it is untouched and
# unalarmed.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MI="$HERE/../scripts/manifest-invariants.sh"
[ -x "$MI" ] || { echo "ac4: $MI not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/manifest-inv-ac4.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state/intent" "$T/build-queue" "$T/built-prds" "$T/parked"

# A parked entry that ALSO happens to look exactly like the AC1 heal
# fixture (blocked would-heal shape) — status is parked, so it must never
# be inspected for that rule at all.
python3 -c "
import json
json.dump({'prds': {'ac4-fixture': {
  'slug': 'ac4-fixture', 'status': 'parked', 'blockers': [], 'iter_log': []
}}}, open('$T/state/manifest.json', 'w'))
"
before_hash="$(sha256sum "$T/state/manifest.json" | awk '{print $1}')"

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

"$MI" --prd-dir "$T"

after_hash="$(sha256sum "$T/state/manifest.json" | awk '{print $1}')"
expect "manifest byte-unchanged" "[ '$before_hash' = '$after_hash' ]"

status="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['ac4-fixture']['status'])")"
expect "status still parked" "[ '$status' = parked ]"

if [ -f "$T/journal.md" ]; then
  expect "no journal line mentions this slug at all" "! grep -q 'ac4-fixture' '$T/journal.md'"
else
  echo "ok  no journal file was even created"
fi

exit $fail
