#!/usr/bin/env bash
# lint_ac3_legacy_prefix_zero_countable.sh —
# PRD-prd-contract-lint AC3.
#
# Given a PRD whose ACs use `AC-1:` prefixes and no `N. ` lines, When lint
# runs, Then it FAILs both naming the legacy-format line AND naming that no
# countable `N. P[0-2] —` acceptance-criterion line was found.
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
for label in \
  "ok: ac-legacy-format/fail -> FAIL ac-legacy-format" \
  "ok: ac-no-lines/fail -> FAIL ac-no-lines"
do
  if grep -qF "$label" <<<"$out"; then
    echo "ok  AC3: $label"
  else
    echo "FAIL: expected label missing from prd-lint-selftest.sh: $label" >&2
    fail=1
  fi
done
exit $fail
