#!/usr/bin/env bash
# scan-deferred-acs.sh — smoke test for PRD-build-deferred-acs AC1.
#
# Points scan-prds.sh at tests/fixtures/ and asserts:
#   * `PRD-fixture-deferred-acs.md` emits `deferred_acs: [1,3,5]`.
#   * `PRD-fixture-no-deferral.md` emits `deferred_acs: []` (default).
#   * Both emit `deferred_ac_reasons: {}` (parser stub for now).
#
# Exit non-zero on any mismatch.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PRD_DIR="$HERE/fixtures"
SCAN="$HERE/../scripts/scan-prds.sh"

[ -x "$SCAN" ] || { echo "scan-deferred-acs: $SCAN not executable" >&2; exit 2; }

out="$(PRD_DIR="$PRD_DIR" "$SCAN")" || { echo "scan-deferred-acs: scan failed" >&2; exit 2; }

fail=0
expect() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "ok  $label"
  else
    echo "FAIL $label  want=$want  got=$got" >&2
    fail=1
  fi
}

# fixture-deferred-acs: list [1,3,5]
got="$(printf '%s' "$out" | /usr/sbin/jq -c '.[] | select(.slug=="fixture-deferred-acs") | .deferred_acs')"
expect "fixture-deferred-acs deferred_acs"  "[1,3,5]"  "$got"

got="$(printf '%s' "$out" | /usr/sbin/jq -c '.[] | select(.slug=="fixture-deferred-acs") | .deferred_ac_reasons')"
expect "fixture-deferred-acs deferred_ac_reasons (stub)"  "{}"  "$got"

# fixture-no-deferral: default empty list
got="$(printf '%s' "$out" | /usr/sbin/jq -c '.[] | select(.slug=="fixture-no-deferral") | .deferred_acs')"
expect "fixture-no-deferral deferred_acs"  "[]"  "$got"

got="$(printf '%s' "$out" | /usr/sbin/jq -c '.[] | select(.slug=="fixture-no-deferral") | .deferred_ac_reasons')"
expect "fixture-no-deferral deferred_ac_reasons"  "{}"  "$got"

exit $fail
