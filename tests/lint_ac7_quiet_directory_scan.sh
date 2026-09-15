#!/usr/bin/env bash
# lint_ac7_quiet_directory_scan.sh —
# PRD-prd-contract-lint AC7.
#
# Given a directory of mixed files, When lint runs with `--quiet`, Then
# output is one line per FAIL only (no PASS lines) and exit reflects the
# worst result.
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
if grep -qF "ok: --quiet -> one FAIL line, no PASS lines, over a mixed directory" <<<"$out"; then
  echo "ok  AC7: --quiet prints FAIL-only lines over a directory scan"
else
  echo "FAIL: expected label missing from prd-lint-selftest.sh" >&2
  fail=1
fi
exit $fail
