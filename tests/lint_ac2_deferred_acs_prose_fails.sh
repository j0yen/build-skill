#!/usr/bin/env bash
# lint_ac2_deferred_acs_prose_fails.sh —
# PRD-prd-contract-lint AC2.
#
# Given a PRD with `deferred_acs: see note below` (prose, not an inline int
# list), When lint runs, Then it FAILs naming the inline-list requirement
# (`deferred_acs must be a list, e.g. [15, 16]`).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/../scripts/prd-lint-selftest.sh"

out="$(bash "$SUITE" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: prd-lint-selftest.sh exited $rc" >&2
  echo "$out" | tail -20 >&2
  exit 1
fi

fail=0
if grep -qF "ok: deferred-acs-prose/fail (real defect: mcphost-code-tools) -> FAIL deferred-acs-prose" <<<"$out"; then
  echo "ok  AC2: prose deferred_acs FAILs naming the inline-list requirement"
else
  echo "FAIL: expected label missing from prd-lint-selftest.sh" >&2
  fail=1
fi
exit $fail
