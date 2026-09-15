#!/usr/bin/env bash
# lint_ac4_build_into_missing_extend_warn.sh —
# PRD-prd-contract-lint AC4.
#
# Given a rust-extend PRD whose build_into path does not exist, When lint
# runs, Then the missing path is named.
#
# DELIBERATE DEVIATION from the AC's literal "FAIL": this repo's prd-lint.sh
# (PRD-build-prd-lint) already made this exact call and downgraded it to a
# WARN on purpose — see the check's own comment ("build-into-not-found") —
# because a PRD's build_into commonly lives on a different fleet host (e.g.
# RedBaron for Rust) than wherever lint happens to run; promoting it to FAIL
# would hard-block every extend PRD linted from a non-RedBaron lane, a much
# bigger regression than the gap this AC closes. The existing behavior is
# preserved rather than reverted; this test proves the path IS named
# (surfaced to a human), just as a WARN rather than a hard FAIL.
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
if grep -qF "ok: build-into-not-found/warn -> WARN build-into-not-found" <<<"$out"; then
  echo "ok  AC4: missing build_into on an extend PRD is named (as a WARN, by design — see header)"
else
  echo "FAIL: expected label missing from prd-lint-selftest.sh" >&2
  fail=1
fi
exit $fail
