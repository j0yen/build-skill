#!/usr/bin/env bash
# lintdr_ac10_explain_shows_both_shapes.sh —
# PRD-build-prd-lint-deferred-reasons-key AC10.
#
# Given `prd-lint.sh --explain deferred-acs-missing-justification`, When
# run, Then stdout shows one example of each accepted key.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/prd-lint.sh"
[ -x "$LINT" ] || { echo "FAIL: $LINT not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

out="$("$LINT" --explain deferred-acs-missing-justification 2>&1)"; rc=$?
expect "AC10: --explain exits 0" "[ $rc -eq 0 ]"
expect "AC10: shows a mock_justifications example" "grep -q 'mock_justifications:.*AC' <<<\"\$out\""
expect "AC10: shows a deferred_ac_reasons example" "grep -q 'deferred_ac_reasons:.*{' <<<\"\$out\""

# Unknown id: exits non-zero, does not print an example.
out2="$("$LINT" --explain not-a-real-check-id 2>&1)"; rc2=$?
expect "AC10: unknown check id exits non-zero" "[ $rc2 -ne 0 ]"

exit $fail
