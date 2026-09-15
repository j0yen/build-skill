#!/usr/bin/env bash
# durheal_ac5_requeue_failure_defers_heal.sh — PRD-build-classification-
# durable-heal AC5.
#
# Given requeue-prd.sh failing (fixture: origin made unreachable, the same
# effect a rejected/refused push has for this AC -- requeue-prd.sh returns
# non-zero either way), When manifest-invariants.sh's needs-classification-
# lint-pass heal runs, Then the cache still reads needs_classification and
# the journal has a `heal deferred (...)` line.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MI="$HERE/../scripts/manifest-invariants.sh"
[ -x "$MI" ] || { echo "ac5: $MI not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/durheal-ac5.XXXXXX")"
trap 'rm -rf "$T"' EXIT

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/prds" 2>/dev/null
mkdir -p "$T/prds/build-queue" "$T/prds/visions" "$T/state/intent"
gc() { git -C "$T/prds" -c user.email=t@t -c user.name=t "$@"; }
touch "$T/prds/visions/ac5.md"

cat > "$T/prds/build-queue/PRD-ac5-fixture.md" <<'EOF'
# PRD ac5-fixture
- Status: needs_classification
- build_target: shell
- Vision: visions/ac5.md

## Acceptance criteria

1. P0 — Given X, When Y, Then Z.
EOF
gc add -A
gc commit -qm "add ac5-fixture"
DEFBR="$(git -C "$T/prds" symbolic-ref --short HEAD)"
git -C "$T/prds" push -q origin "$DEFBR"

# Fixture: origin becomes unreachable before requeue-prd.sh runs, so its
# mandatory `git pull --rebase --autostash` fails and it exits non-zero
# without ever writing the file -- the same "requeue didn't land" outcome
# a rejected/refused push produces, just surfaced at the pull step instead
# of the push step.
rm -rf "$T/origin.git"

python3 -c "
import json
json.dump({'prds': {'ac5-fixture': {
  'slug': 'ac5-fixture', 'status': 'needs_classification',
  'needs_classification_reason': 'prd-lint: build-target-unknown: was bogus',
  'path': '$T/prds/build-queue/PRD-ac5-fixture.md'
}}}, open('$T/state/manifest.json', 'w'))
"

export BUILD_STATE_DIR="$T/state"
export BUILD_MANIFEST="$T/state/manifest.json"
export LOCK="$T/state/tick.lock"
export JOURNAL="$T/journal.md"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

"$HERE/../scripts/prd-lint.sh" "$T/prds/build-queue/PRD-ac5-fixture.md" >/dev/null
expect "fixture PRD passes prd-lint (precondition)" "[ $? -eq 0 ]"

"$MI" --prd-dir "$T/prds"

status="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['ac5-fixture']['status'])")"
expect "cache still reads needs_classification (heal deferred, not applied)" "[ '$status' = needs_classification ]"

file_status="$(grep -E '^- *Status:' "$T/prds/build-queue/PRD-ac5-fixture.md" | head -n1 | sed -E 's/^- *Status:[[:space:]]*//')"
expect "PRD file also unchanged (the pull failure happens before any write)" "[ '$file_status' = needs_classification ]"

expect "journal has a heal-deferred line for this rule" \
  "grep -q 'heal  deferred  (rule=needs-classification-lint-pass' '$T/journal.md'"

exit $fail
