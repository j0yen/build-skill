#!/usr/bin/env bash
# opauth_ac11_lint_warns_no_authorization.sh —
# PRD-build-operator-authorization-contract AC11.
#
# Given prd-lint.sh run over a PRD fixture with an AC mentioning hcloud and
# no Operator-authorization: key, When lint runs, Then it emits a WARN (not
# FAIL) naming the AC line and the missing key.
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
if grep -qF "ok: real-box-ac-no-authorization/warn -> WARN real-box-ac-no-authorization" <<<"$out"; then
  echo "ok  AC11: real-box AC with no Operator-authorization key WARNs"
else
  echo "FAIL: expected label missing from prd-lint-selftest.sh" >&2
  fail=1
fi
exit $fail
