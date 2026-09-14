#!/usr/bin/env bash
# opauth_ac6_deferral_scope_mismatch_named.sh —
# PRD-build-operator-authorization-contract AC6.
#
# Given the same deferral line but its text does name why the action falls
# outside the stated scope, When verdict-receipts.sh scan reads it, Then
# the scan does not flag it. Runs the real dedicated fixture
# (verdict-receipts-selftest.sh's opauth-AC6 block), same model as AC5's
# wrapper.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/../scripts/verdict-receipts-selftest.sh"

out="$(bash "$SUITE" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: verdict-receipts-selftest.sh exited $rc" >&2
  echo "$out" | tail -20 >&2
  exit 1
fi

fail=0
for want in \
  "PASS  opauth-AC6 scope-naming deferral passes" \
  "PASS  opauth-AC6 prints PASS" \
  "PASS  opauth-noauth deferral unaffected without a key"
do
  if grep -qF "$want" <<<"$out"; then
    echo "ok  $want"
  else
    echo "FAIL: expected label missing from verdict-receipts-selftest.sh: $want" >&2
    fail=1
  fi
done
exit $fail
