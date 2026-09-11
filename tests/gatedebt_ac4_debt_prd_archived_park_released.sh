#!/usr/bin/env bash
# gatedebt_ac4_debt_prd_archived_park_released.sh — PRD-build-gate-debt-
# auto-prd AC4.
#
# Given the debt PRD archived, When the reconciler runs (here:
# gate-debt.sh release-check), Then the parked PRD is selectable again
# (its Depends-on line is gone — SKILL.md's existing Depends-on gate does
# the actual re-admission, this only clears the marker) and the journal
# has `gate-debt  released`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GD="$HERE/../scripts/gate-debt.sh"
[ -x "$GD" ] || { echo "ac4: $GD not executable" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gatedebt-ac4.XXXXXX")"
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

DEBT_NAME="PRD-fake-repo-gate-debt-1234567.md"
cat > "$ROOT/prds/built-prds/$DEBT_NAME" <<EOF
# PRD: fake-repo-gate-debt-1234567

- Status: built
- build_target: rust-extend
- build_into: /tmp/fake-repo
- Vision: visions/buildloop-operations.md
EOF

cat > "$ROOT/prds/build-queue/PRD-blocked-fixture.md" <<EOF
# PRD: blocked-fixture

- Status: queued
- Depends-on: ${DEBT_NAME}
- build_target: rust-extend
- build_into: /tmp/fake-repo
- Vision: visions/buildloop-operations.md
EOF

git -C "$ROOT/prds" add -A
git -C "$ROOT/prds" -c user.name=t -c user.email=t@t commit -q -m init
BR="$(git -C "$ROOT/prds" symbolic-ref --short HEAD)"
git -C "$ROOT/prds" push -q origin "$BR"

JOURNAL="$ROOT/journal.md"
: > "$JOURNAL"

"$GD" release-check --prd-dir "$ROOT/prds" --journal "$JOURNAL"

git -C "$ROOT/prds" pull -q --rebase
blocked="$ROOT/prds/build-queue/PRD-blocked-fixture.md"
expect "Depends-on line removed (parked PRD is selectable again)" "! grep -q '^- Depends-on:' '$blocked'"
expect "journal has gate-debt released line naming both PRDs" \
  "grep -q \"blocked-fixture  gate-debt  released  (prd=blocked-fixture behind=\$DEBT_NAME)\" '$JOURNAL'"
expect "origin reflects the release" \
  "! git --git-dir='$ROOT/origin.git' show '$BR:build-queue/PRD-blocked-fixture.md' | grep -q '^- Depends-on:'"

# A PRD whose Depends-on target has NOT archived yet is left untouched.
cat > "$ROOT/prds/build-queue/PRD-still-waiting.md" <<EOF
# PRD: still-waiting

- Status: queued
- Depends-on: PRD-other-gate-debt-abcdef1.md
- build_target: rust-extend
- build_into: /tmp/other-repo
- Vision: visions/buildloop-operations.md
EOF
git -C "$ROOT/prds" add -A
git -C "$ROOT/prds" -c user.name=t -c user.email=t@t commit -q -m "add still-waiting"
git -C "$ROOT/prds" push -q origin "$BR"

"$GD" release-check --prd-dir "$ROOT/prds" --journal "$JOURNAL"
expect "still-waiting keeps its Depends-on (target never archived)" \
  "grep -q '^- Depends-on: PRD-other-gate-debt-abcdef1.md' '$ROOT/prds/build-queue/PRD-still-waiting.md'"

exit $fail
