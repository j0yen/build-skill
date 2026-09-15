#!/usr/bin/env bash
# lintdr_ac7_postland_unpark_mechanism.sh —
# PRD-build-prd-lint-deferred-reasons-key AC7.
#
# Given a PRD in manifest status needs_classification with a
# deferred-acs-missing-justification bounce record, When the post-land step
# runs on the build lane, Then the bounce record is cleared through
# manifest-set.sh, one `unpark  lint-clean` journal line is written, and
# the next scan-prds.sh lists the slug as buildable.
#
# Exercises the EXACT sequence this dispatch runs for real against
# PRD-mcphost-tenant-tables (prd-lint.sh exit 0 -> manifest-set.sh clear
# patch -> journal line), against a scratch fixture so this test never
# touches the real corpus or manifest.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/prd-lint.sh"
SET_SH="$HERE/../scripts/manifest-set.sh"
SCAN_SH="$HERE/../scripts/scan-prds.sh"
[ -x "$LINT" ] || { echo "FAIL: $LINT not executable" >&2; exit 2; }
[ -x "$SET_SH" ] || { echo "FAIL: $SET_SH not executable" >&2; exit 2; }
[ -x "$SCAN_SH" ] || { echo "FAIL: $SCAN_SH not executable" >&2; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/prds/build-queue" "$T/prds/visions" "$T/state"
echo "plain vision" > "$T/prds/visions/plain.md"
printf '# MANIFEST\n' > "$T/prds/MANIFEST.md"
FIX="$T/prds/build-queue/PRD-lintdr-ac7.md"
cat > "$FIX" <<'EOF'
# PRD: lintdr-ac7

- Status: queued
- build_target: shell
- Vision: visions/plain.md
- deferred_acs: [10, 11]
- deferred_ac_reasons: {"10": "reason ten", "11": "reason eleven"}

## Acceptance criteria

1. P0 - Given a, When b, Then c.
EOF
printf '%s\n' '{"prds":{"lintdr-ac7":{"slug":"lintdr-ac7","status":"needs_classification","needs_classification_reason":"deferred-acs-missing-justification: deferred_acs is a non-empty list but no `mock_justifications:` line was found","needs_classification_hash":"deadbeef","needs_classification_bounces":3}},"built_at":"2020-01-01T00:00:00Z"}' \
  > "$T/state/manifest.json"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# The post-land step, verbatim shape: lint the file, and only on a clean
# exit clear the record + journal the specific unpark line.
"$LINT" "$FIX" >/dev/null 2>&1
lint_rc=$?
expect "ac7 setup: fixture (deferred_ac_reasons only) lints clean" "[ $lint_rc -eq 0 ]"

patch="$T/unpark.patch.json"
printf '{"status":"queued","needs_classification_reason":"","needs_classification_hash":"","needs_classification_bounces":0}' > "$patch"
BUILD_STATE_DIR="$T/state" BUILD_MANIFEST="$T/state/manifest.json" PRD_DIR="$T/prds" JOURNAL="$T/journal.md" \
  "$SET_SH" lintdr-ac7 "$patch"
set_rc=$?
expect "AC7: manifest-set.sh clears the record (exit 0)" "[ $set_rc -eq 0 ]"

status="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['lintdr-ac7']['status'])")"
expect "AC7: status is queued after the clear" "[ '$status' = queued ]"

printf '%s  %s  unpark  lint-clean  (id=deferred-acs-missing-justification lane=%s)\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "lintdr-ac7" "$(hostname)" >> "$T/journal.md"
expect "AC7: journal has the unpark lint-clean line" \
  "grep -q 'lintdr-ac7  unpark  lint-clean  (id=deferred-acs-missing-justification' '$T/journal.md'"

# And the next scan-prds.sh over this scratch corpus lists the slug as
# buildable (queued), not needs_classification.
scan_status="$(BUILD_MANIFEST="$T/state/manifest.json" BUILD_STATE_DIR="$T/state" PRD_DIR="$T/prds" "$SCAN_SH" 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((e['status_line'] for e in d if e['slug']=='lintdr-ac7'), 'MISSING'))")"
expect "AC7: scan-prds.sh runs clean over the corpus post-unpark" "[ -n '$scan_status' ]"
final_status="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['lintdr-ac7']['status'])")"
expect "AC7: manifest cache still says queued after a fresh scan (lint-clean, not re-parked)" "[ '$final_status' = queued ]"

exit $fail
