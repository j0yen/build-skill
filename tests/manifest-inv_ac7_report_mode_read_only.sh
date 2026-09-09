#!/usr/bin/env bash
# manifest-inv_ac7_report_mode_read_only.sh — PRD-build-manifest-invariants
# AC7.
#
# Given --report mode on a manifest with two violations, When it runs, Then
# both are printed and the manifest file hash is unchanged.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MI="$HERE/../scripts/manifest-invariants.sh"
[ -x "$MI" ] || { echo "ac7: $MI not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/manifest-inv-ac7.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state/intent" "$T/build-queue" "$T/built-prds" "$T/parked"

python3 -c "
import json
json.dump({'prds': {
  'ac7-heal-fixture': {
    'slug': 'ac7-heal-fixture', 'status': 'blocked', 'blockers': [], 'iter_log': []
  },
  'ac7-alarm-fixture': {
    'slug': 'ac7-alarm-fixture', 'status': 'nonsense-status'
  },
}}, open('$T/state/manifest.json', 'w'))
"
before_hash="$(sha256sum "$T/state/manifest.json" | awk '{print $1}')"
before_mtime="$(stat -c %Y "$T/state/manifest.json")"

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

sleep 1  # so an accidental mtime bump would be observable
out="$("$MI" --report --prd-dir "$T" --format json)"; rc=$?
expect "exits 0" "[ $rc -eq 0 ]"
expect "prints the would-be heal"  "grep -q 'ac7-heal-fixture' <<<\"\$out\""
expect "prints the would-be alarm" "grep -q 'ac7-alarm-fixture' <<<\"\$out\""
expect "reports mode=report"       "grep -q '\"mode\": *\"report\"' <<<\"\$out\""

after_hash="$(sha256sum "$T/state/manifest.json" | awk '{print $1}')"
after_mtime="$(stat -c %Y "$T/state/manifest.json")"
expect "manifest hash unchanged"  "[ '$before_hash' = '$after_hash' ]"
expect "manifest mtime unchanged" "[ '$before_mtime' = '$after_mtime' ]"
expect "no journal file was created (report mode writes nothing)" "[ ! -f '$T/journal.md' ]"

# Text format too, since --format defaults to table.
out_text="$("$MI" --report --prd-dir "$T")"
expect "table format also lists both fixtures" \
  "grep -q 'ac7-heal-fixture' <<<\"\$out_text\" && grep -q 'ac7-alarm-fixture' <<<\"\$out_text\""

exit $fail
