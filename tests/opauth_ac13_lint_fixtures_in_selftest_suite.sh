#!/usr/bin/env bash
# opauth_ac13_lint_fixtures_in_selftest_suite.sh —
# PRD-build-operator-authorization-contract AC13.
#
# Given prd-lint-selftest.sh's fixture suite, When the two new fixtures
# (warn-triggering, warn-suppressed) are run, Then both assert the exact
# expected exit/output, matching the existing fixture pattern in that file.
# Distinct from AC11/AC12 (which each check ONE fixture's own behavior):
# this checks that both fixtures exist side by side, self-contained, in the
# same suite run — the "added under prd-lint-selftest.sh's existing fixture
# pattern" requirement (P1 requirement 9) itself.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SELFTEST="$HERE/../scripts/prd-lint-selftest.sh"

fail=0

grep -qF "real-box-ac-no-authorization/warn" "$SELFTEST" \
  && grep -qF "real-box-ac-no-authorization/pass" "$SELFTEST" \
  && echo "ok  AC13: prd-lint-selftest.sh source defines both the warn and pass fixtures" \
  || { echo "FAIL: prd-lint-selftest.sh is missing one of the two fixture cases" >&2; fail=1; }

out="$(bash "$SELFTEST" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: prd-lint-selftest.sh exited $rc" >&2
  echo "$out" | tail -20 >&2
  exit 1
fi

for want in \
  "ok: real-box-ac-no-authorization/warn -> WARN real-box-ac-no-authorization" \
  "ok: real-box-ac-no-authorization/pass (key present) -> no real-box-ac-no-authorization"
do
  if grep -qF "$want" <<<"$out"; then
    echo "ok  AC13: $want"
  else
    echo "FAIL: expected label missing from prd-lint-selftest.sh run: $want" >&2
    fail=1
  fi
done

grep -qF "SELFTEST PASSED" <<<"$out" \
  && echo "ok  AC13: prd-lint-selftest.sh's own suite verdict is PASSED with both fixtures in place" \
  || { echo "FAIL: prd-lint-selftest.sh did not report SELFTEST PASSED" >&2; fail=1; }

exit $fail
