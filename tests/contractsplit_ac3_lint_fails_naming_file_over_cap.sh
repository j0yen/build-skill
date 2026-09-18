#!/usr/bin/env bash
# contractsplit_ac3_lint_fails_naming_file_over_cap.sh —
# PRD-build-branch-contract-split AC3: given a test edit adding line 401
# to the contract, when lint-contract-size.sh runs, then it exits 1
# naming the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
LINT="$REPO_ROOT/scripts/lint-contract-size.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then
    echo "ok  $label"
  else
    echo "FAIL $label" >&2
    fail=1
  fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/contractsplit-ac3.XXXXXX")"
trap 'rm -rf "$T"' EXIT

cp "$REPO_ROOT/docs/branch-contract.md" "$T/contract-over.md"
for i in $(seq 1 250); do echo "filler line $i" >> "$T/contract-over.md"; done
lines="$(wc -l < "$T/contract-over.md")"
expect "AC3: fixture contract is over 400 lines (sanity, got $lines)" "[ '$lines' -gt 400 ]"

out="$(bash "$LINT" --contract "$T/contract-over.md" --skill "$REPO_ROOT/SKILL.md" 2>&1)"
rc=$?
expect "AC3: lint exits 1 on an over-cap contract" "[ $rc -eq 1 ]"
expect "AC3: lint names the offending file" "grep -qF \"$T/contract-over.md\" <<<\"\$out\""

exit "$fail"
