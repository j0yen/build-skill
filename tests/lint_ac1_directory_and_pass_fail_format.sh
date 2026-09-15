#!/usr/bin/env bash
# lint_ac1_directory_and_pass_fail_format.sh —
# PRD-prd-contract-lint AC1.
#
# Given prd-lint.sh's `--format pass-fail`, When run over a file, Then it
# prints exactly `PASS <file>` for a clean file and `FAIL <file>: <finding>
# [, <finding>...]` for a failing one; When run over a directory argument,
# Then it expands to that directory's PRD-*.md files and exits 0 only when
# every one passes.
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
  "ok: directory-arg -> expands to its 2 PRD-*.md files" \
  "ok: format pass-fail -> 'PASS <file>' on a clean file" \
  "ok: format pass-fail -> 'FAIL <file>: <finding>...' on a failing file"
do
  if grep -qF "$label" <<<"$out"; then
    echo "ok  AC1: $label"
  else
    echo "FAIL: expected label missing from prd-lint-selftest.sh: $label" >&2
    fail=1
  fi
done
exit $fail
