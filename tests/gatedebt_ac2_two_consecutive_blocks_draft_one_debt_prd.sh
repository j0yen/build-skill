#!/usr/bin/env bash
# gatedebt_ac2_two_consecutive_blocks_draft_one_debt_prd.sh — PRD-build-
# gate-debt-auto-prd AC2.
#
# Given two consecutive blocked gates on one HEAD with the same inherited
# set, When gate-debt.sh check runs after the second, Then exactly one
# PRD-<repo>-gate-debt-<shortsha>.md exists in build-queue/, passes
# prd-lint.sh, and contains one `N. P0 —` line per inherited finding.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GD="$HERE/../scripts/gate-debt.sh"
PRD_LINT="$HERE/../scripts/prd-lint.sh"
[ -x "$GD" ] || { echo "ac2: $GD not executable" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gatedebt-ac2.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# PRD-dir fixture: a scratch git repo (never touches ~/Documents/PRDs).
git init -q --bare "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$ROOT/prds"
mkdir -p "$ROOT/prds/build-queue" "$ROOT/prds/built-prds" "$ROOT/prds/visions"
: > "$ROOT/prds/visions/buildloop-operations.md"
FAKE_REPO="$ROOT/fake-repo"
mkdir -p "$FAKE_REPO"
git -C "$ROOT/prds" add -A
git -C "$ROOT/prds" -c user.name=t -c user.email=t@t commit -q -m init
BR="$(git -C "$ROOT/prds" symbolic-ref --short HEAD)"
git -C "$ROOT/prds" push -q origin "$BR"

STATE="$ROOT/state"
JOURNAL="$ROOT/journal.md"
: > "$JOURNAL"

HEAD_SHA="deadbeefcafefeed0000000000000000000abcd"
VERDICT="$ROOT/last-verdict.json"
cat > "$VERDICT" <<EOF
{"blocks":[{"receipt":"risk-gate","finding":"unsafe block without SAFETY comment","path":"src/runs.rs","scope":"inherited"}],"in_scope":0,"inherited":1}
EOF

# Run 1: first sighting, tracked but not yet drafted.
out1="$("$GD" check "$FAKE_REPO" "$HEAD_SHA" --verdict-file "$VERDICT" --prd-dir "$ROOT/prds" --state-dir "$STATE" --journal "$JOURNAL")"
expect "run 1 does not draft yet" "! ls '$ROOT/prds/build-queue/' | grep -q gate-debt"

# Run 2: same head, same inherited set -> consecutive=2 -> drafts.
out2="$("$GD" check "$FAKE_REPO" "$HEAD_SHA" --verdict-file "$VERDICT" --prd-dir "$ROOT/prds" --state-dir "$STATE" --journal "$JOURNAL")"

drafted="$(ls "$ROOT/prds/build-queue/" | grep gate-debt || true)"
expect "exactly one debt PRD file exists" "[ \"\$(wc -l <<<\"\$drafted\")\" -eq 1 ] && [ -n \"\$drafted\" ]"
expect "filename matches PRD-<repo>-gate-debt-<shortsha>.md" \
  "[[ \"\$drafted\" == PRD-fake-repo-gate-debt-*.md ]]"

drafted_path="$ROOT/prds/build-queue/$drafted"
expect "drafted file exists on disk" "[ -f '$drafted_path' ]"
expect "passes prd-lint.sh" "\"$PRD_LINT\" '$drafted_path'"
expect "exactly one N. P0 line (one per inherited finding)" \
  "[ \"\$(grep -cE '^[0-9]+\. P0 —' '$drafted_path')\" -eq 1 ]"
expect "AC line names the finding" "grep -q 'risk-gate passes: unsafe block without SAFETY comment' '$drafted_path'"
expect "build_priority: high" "grep -q '^- build_priority: high' '$drafted_path'"
expect "build_into names the repo" "grep -q '^- build_into: $FAKE_REPO' '$drafted_path'"
expect "test_prefix names the shortsha" "grep -qE '^- test_prefix: gatedebt-[0-9a-f]{7}' '$drafted_path'"

# Idempotent: a third check call with the same (head, set) does not draft a
# second file.
out3="$("$GD" check "$FAKE_REPO" "$HEAD_SHA" --verdict-file "$VERDICT" --prd-dir "$ROOT/prds" --state-dir "$STATE" --journal "$JOURNAL")"
drafted_after="$(ls "$ROOT/prds/build-queue/" | grep -c gate-debt || true)"
expect "still exactly one debt PRD after a third check" "[ '$drafted_after' -eq 1 ]"
expect "third call reports already-drafted" "grep -q already-drafted <<<\"\$out3\""

exit $fail
