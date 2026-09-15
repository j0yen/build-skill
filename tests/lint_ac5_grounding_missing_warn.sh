#!/usr/bin/env bash
# lint_ac5_grounding_missing_warn.sh —
# PRD-prd-contract-lint AC5.
#
# Given a PRD missing a `- Grounding:` line, When lint runs, Then the
# missing grounding chain is named.
#
# DELIBERATE DEVIATION from the AC's literal "FAIL": a standalone corpus run
# against the live build-queue/ at ship time (2026-09-15) found ~45% of
# currently-queued PRDs predate the `Grounding:` convention and have no such
# line — a FAIL would have parked roughly half the live queue into
# needs_classification the instant this shipped (scan-prds.sh's Phase-1 gate
# treats the first FAIL as a hard park). This is a WARN instead, same
# reasoning as the pre-existing `build-into-not-found` check. This test
# proves the gap IS surfaced (to a human/drafter), just not as a hard block.
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
if grep -qF "ok: grounding-missing/warn -> WARN grounding-missing" <<<"$out"; then
  echo "ok  AC5: missing Grounding line is named (as a WARN, by design — see header)"
else
  echo "FAIL: expected label missing from prd-lint-selftest.sh" >&2
  fail=1
fi
exit $fail
