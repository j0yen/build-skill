#!/usr/bin/env bash
# durheal_ac4b_report_mode_never_requeues.sh — regression guard for
# PRD-build-classification-durable-heal requirement 3/AC4.
#
# manifest-invariants.sh --report is documented read-only (see
# manifest-inv_ac7_report_mode_read_only.sh). Requirement 3 routes the
# real apply path through requeue-prd.sh (a commit+push), so --report
# must predict that heal WITHOUT ever calling requeue-prd.sh -- otherwise
# a read-only status check would silently commit and push to the shared
# PRDs clone. This is exactly the gap the shipped AC7 fixture couldn't
# catch (its fixture has no needs_classification entry at all).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MI="$HERE/../scripts/manifest-invariants.sh"
[ -x "$MI" ] || { echo "ac4b: $MI not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/durheal-ac4b.XXXXXX")"
trap 'rm -rf "$T"' EXIT

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/prds" 2>/dev/null
mkdir -p "$T/prds/build-queue" "$T/prds/visions" "$T/state/intent"
gc() { git -C "$T/prds" -c user.email=t@t -c user.name=t "$@"; }
touch "$T/prds/visions/ac4b.md"

cat > "$T/prds/build-queue/PRD-ac4b-fixture.md" <<'EOF'
# PRD ac4b-fixture
- Status: needs_classification
- build_target: shell
- Vision: visions/ac4b.md

## Acceptance criteria

1. P0 — Given X, When Y, Then Z.
EOF
gc add -A
gc commit -qm "add ac4b-fixture"
DEFBR="$(git -C "$T/prds" symbolic-ref --short HEAD)"
git -C "$T/prds" push -q origin "$DEFBR"

python3 -c "
import json
json.dump({'prds': {'ac4b-fixture': {
  'slug': 'ac4b-fixture', 'status': 'needs_classification',
  'needs_classification_reason': 'prd-lint: build-target-unknown: was bogus',
  'path': '$T/prds/build-queue/PRD-ac4b-fixture.md'
}}}, open('$T/state/manifest.json', 'w'))
"
manifest_hash_before="$(sha256sum "$T/state/manifest.json" | awk '{print $1}')"
head_before="$(git -C "$T/prds" rev-parse HEAD)"

export BUILD_STATE_DIR="$T/state"
export BUILD_MANIFEST="$T/state/manifest.json"
export LOCK="$T/state/tick.lock"
export JOURNAL="$T/journal.md"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

"$HERE/../scripts/prd-lint.sh" "$T/prds/build-queue/PRD-ac4b-fixture.md" >/dev/null
expect "fixture PRD passes prd-lint (precondition)" "[ $? -eq 0 ]"

out="$("$MI" --prd-dir "$T/prds" --report)"; rc=$?
expect "--report exits 0" "[ $rc -eq 0 ]"
expect "--report predicts the heal" "grep -q 'ac4b-fixture' <<<\"\$out\""

manifest_hash_after="$(sha256sum "$T/state/manifest.json" | awk '{print $1}')"
head_after="$(git -C "$T/prds" rev-parse HEAD)"
expect "manifest cache byte-unchanged" "[ '$manifest_hash_before' = '$manifest_hash_after' ]"
expect "no commit landed in the PRDs clone (requeue-prd.sh never called)" "[ '$head_before' = '$head_after' ]"
expect "PRD file itself still reads needs_classification" \
  "grep -qxe '- Status: needs_classification' '$T/prds/build-queue/PRD-ac4b-fixture.md'"

exit $fail
