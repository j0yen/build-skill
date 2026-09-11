#!/usr/bin/env bash
# gatedebt_ac3_blocked_prd_parked_behind_debt_prd.sh — PRD-build-gate-debt-
# auto-prd AC3.
#
# Given the debt PRD drafted, When the tick continues, Then the blocked
# PRD's frontmatter has Depends-on: PRD-<repo>-gate-debt-<shortsha>.md and
# Status: queued, and the journal has `gate-debt  parked`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GD="$HERE/../scripts/gate-debt.sh"
[ -x "$GD" ] || { echo "ac3: $GD not executable" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gatedebt-ac3.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

git init -q --bare "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$ROOT/prds"
mkdir -p "$ROOT/prds/build-queue" "$ROOT/prds/built-prds" "$ROOT/prds/visions"
: > "$ROOT/prds/visions/buildloop-operations.md"
FAKE_REPO="$ROOT/fake-repo"
mkdir -p "$FAKE_REPO"

# The PRD that was actually gate-pending on this repo when the block repeated.
cat > "$ROOT/prds/build-queue/PRD-blocked-fixture.md" <<EOF
# PRD: blocked-fixture

- Status: building
- build_target: rust-extend
- build_into: ${FAKE_REPO}
- Vision: visions/buildloop-operations.md
EOF

git -C "$ROOT/prds" add -A
git -C "$ROOT/prds" -c user.name=t -c user.email=t@t commit -q -m init
BR="$(git -C "$ROOT/prds" symbolic-ref --short HEAD)"
git -C "$ROOT/prds" push -q origin "$BR"

STATE="$ROOT/state"
JOURNAL="$ROOT/journal.md"
: > "$JOURNAL"

HEAD_SHA="1234567890abcdef1234567890abcdef12345678"
VERDICT="$ROOT/last-verdict.json"
cat > "$VERDICT" <<EOF
{"blocks":[{"receipt":"risk-gate","finding":"unsafe block without SAFETY comment","path":"src/runs.rs","scope":"inherited"}],"in_scope":0,"inherited":1}
EOF

"$GD" check "$FAKE_REPO" "$HEAD_SHA" --verdict-file "$VERDICT" --prd-dir "$ROOT/prds" --state-dir "$STATE" --journal "$JOURNAL" >/dev/null
"$GD" check "$FAKE_REPO" "$HEAD_SHA" --verdict-file "$VERDICT" --prd-dir "$ROOT/prds" --state-dir "$STATE" --journal "$JOURNAL" >/dev/null

drafted="$(ls "$ROOT/prds/build-queue/" | grep gate-debt || true)"
expect "debt PRD was drafted" "[ -n '$drafted' ]"

blocked="$ROOT/prds/build-queue/PRD-blocked-fixture.md"
git -C "$ROOT/prds" pull -q --rebase
expect "blocked PRD Depends-on names the debt PRD" "grep -q \"^- Depends-on: \$drafted\$\" '$blocked'"
expect "blocked PRD Status is queued" "grep -q '^- Status: queued' '$blocked'"
expect "journal has gate-debt parked line naming both PRDs" \
  "grep -q 'blocked-fixture  gate-debt  parked  (prd=blocked-fixture behind='\"\$drafted\"')' '$JOURNAL'"
expect "origin reflects the park (pushed, not just local)" \
  "git --git-dir='$ROOT/origin.git' show '$BR:build-queue/PRD-blocked-fixture.md' | grep -q '^- Status: queued'"

exit $fail
