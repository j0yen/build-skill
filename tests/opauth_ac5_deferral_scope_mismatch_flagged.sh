#!/usr/bin/env bash
# opauth_ac5_deferral_scope_mismatch_flagged.sh —
# PRD-build-operator-authorization-contract AC5.
#
# Given a journal/PRD deferral line for an AC covered by a present, in-scope
# Operator-authorization, When verdict-receipts.sh scan reads it and the
# deferral text does not name a scope mismatch, Then the scan reports it as
# a bad claim (non-zero exit, FAIL line naming the file and line). This
# PRD's own dedicated fixture (verdict-receipts-selftest.sh's opauth-AC5/
# AC6 block) already exercises this against the real verdict-receipts.sh
# code — this wrapper runs that real fixture rather than re-implementing
# it, so a future edit that silently drops the coverage fails here too.
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
  "PASS  opauth-AC5 unscoped deferral exits nonzero" \
  "PASS  opauth-AC5 flags operator-authorization-deferral" \
  "PASS  opauth-AC5 names the PRD carrying the authorization"
do
  if grep -qF "$want" <<<"$out"; then
    echo "ok  $want"
  else
    echo "FAIL: expected label missing from verdict-receipts-selftest.sh: $want" >&2
    fail=1
  fi
done
exit $fail
