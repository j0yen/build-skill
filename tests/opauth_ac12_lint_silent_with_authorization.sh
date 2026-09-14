#!/usr/bin/env bash
# opauth_ac12_lint_silent_with_authorization.sh —
# PRD-build-operator-authorization-contract AC12.
#
# Given the same fixture with Operator-authorization: present, When lint
# runs, Then no WARN is emitted for that check.
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
if grep -qF "ok: real-box-ac-no-authorization/pass (key present) -> no real-box-ac-no-authorization" <<<"$out"; then
  echo "ok  AC12: real-box AC with Operator-authorization key present is silent"
else
  echo "FAIL: expected label missing from prd-lint-selftest.sh" >&2
  fail=1
fi
exit $fail
