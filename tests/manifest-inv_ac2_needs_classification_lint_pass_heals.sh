#!/usr/bin/env bash
# manifest-inv_ac2_needs_classification_lint_pass_heals.sh — PRD-build-
# manifest-invariants AC2.
#
# Given a needs_classification entry whose PRD file passes prd-lint, When
# the reconciler runs, Then the entry is queued and the reason field
# cleared.
#
# Updated for PRD-build-classification-durable-heal requirement 3: the
# heal now requeues the FILE (commit+push, via requeue-prd.sh) BEFORE it
# ever patches the cache -- so this fixture must be a real git repo with a
# pushable origin, not a bare tmpdir. Before this PRD, this heal patched
# the manifest cache directly without touching the file at all, which is
# exactly the "cache says queued, file still says needs_classification"
# trap the 2026-09-13 mcphost-agent-consent incident hit.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MI="$HERE/../scripts/manifest-invariants.sh"
[ -x "$MI" ] || { echo "ac2: $MI not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/manifest-inv-ac2.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# ---- git fixture: bare origin + one clone, same shape requeue-prd.sh and
# mark-needs-classification.sh's own selftests use -------------------------
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/prds" 2>/dev/null
mkdir -p "$T/prds/build-queue" "$T/prds/built-prds" "$T/prds/parked" "$T/prds/visions" "$T/state/intent"
gc() { git -C "$T/prds" -c user.email=t@t -c user.name=t "$@"; }
touch "$T/prds/visions/ac2.md"

cat > "$T/prds/build-queue/PRD-ac2-fixture.md" <<'EOF'
# PRD ac2-fixture
- Status: needs_classification
- build_target: shell
- Vision: visions/ac2.md

## Acceptance criteria

1. P0 — Given X, When Y, Then Z.
EOF
gc add -A
gc commit -qm "add ac2-fixture"
DEFBR="$(git -C "$T/prds" symbolic-ref --short HEAD)"
git -C "$T/prds" push -q origin "$DEFBR"

python3 -c "
import json
json.dump({'prds': {'ac2-fixture': {
  'slug': 'ac2-fixture', 'status': 'needs_classification',
  'needs_classification_reason': 'prd-lint: build-target-unknown: was bogus',
  'path': '$T/prds/build-queue/PRD-ac2-fixture.md'
}}}, open('$T/state/manifest.json', 'w'))
"

export BUILD_STATE_DIR="$T/state"
export BUILD_MANIFEST="$T/state/manifest.json"
export LOCK="$T/state/tick.lock"
export JOURNAL="$T/journal.md"
export PATH="/usr/bin:/bin:$(dirname "$(command -v git)")"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# Sanity: the fixture file genuinely passes prd-lint (else this test would
# pass for the wrong reason).
"$HERE/../scripts/prd-lint.sh" "$T/prds/build-queue/PRD-ac2-fixture.md" >/dev/null
expect "fixture PRD passes prd-lint (precondition)" "[ $? -eq 0 ]"

"$MI" --prd-dir "$T/prds"

status="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['ac2-fixture']['status'])")"
expect "entry healed to queued" "[ '$status' = queued ]"

reason="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['ac2-fixture']['needs_classification_reason'])")"
expect "reason field cleared" "[ -z '$reason' ]"

rule="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['ac2-fixture']['invariants_audit_log'][0]['rule'])")"
expect "audit log names the rule" "[ '$rule' = needs-classification-lint-pass ]"

# req 3: the FILE itself (not just the cache) is durably queued, committed
# and pushed -- this is the whole point of routing the heal through
# requeue-prd.sh instead of patching the cache directly.
file_status="$(grep -E '^- *Status:' "$T/prds/build-queue/PRD-ac2-fixture.md" | head -n1 | sed -E 's/^- *Status:[[:space:]]*//')"
expect "PRD file itself reads Status: queued (not just the cache)" "[ '$file_status' = queued ]"
expect "the requeue landed a commit" "[ \"\$(git -C '$T/origin.git' log --oneline | wc -l)\" -eq 2 ]"

exit $fail
