#!/usr/bin/env bash
# extend-gate-reviewer-auth-selftest.sh — the one entrypoint for
# PRD-build-reviewer-agent-auth-contract's fixture coverage (test_prefix
# revauth). Runs every tests/revauth_ac*.sh:
#
#   AC1/AC2 — named auth resolution (env vs environment.d), the receipt's
#             own auth_source field, the journal's reviewer_auth= token.
#   AC3     — the preflight probe: no source yields a token -> incomplete
#             infra=reviewer-agent:auth-missing before any receipt
#             producer runs, wall <= 90s, skip_reason names every source
#             checked.
#   AC4     — the fixture token prefix never appears in the journal,
#             target/autobuilder/, or the gate's own stdout/stderr, on
#             both a resolved-token run and an auth-missing run.
#   AC5     — a mid-run auth failure (token revoked between the probe and
#             the real reviewer call) is classified distinctly
#             (_reviewer_infra_kind=auth) with the real error text carried
#             even though stderr was empty.
#   AC6     — gate-then-land.sh's own (unmodified) exhaustion/decision
#             logic already names the auth sources checked, because its
#             decision text interpolates the infra note verbatim.
#
# AC7 (docs/branch-contract.md's reviewer-auth paragraph) and AC8 (every
# previously-green selftest stays green) are not covered by this file —
# AC7 is read, not run; AC8 is the responsibility of scripts/run-
# selftests.sh's own --all sweep, not a fixture this entrypoint owns.
#
# Usage: extend-gate-reviewer-auth-selftest.sh
#
# Exit: 0 all green | 1 one or more failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

fail_n=0
shopt -s nullglob
for f in "$SKILL_DIR"/tests/revauth_ac*.sh; do
  echo "== extend-gate-reviewer-auth-selftest: $(basename "$f") ==" >&2
  bash "$f"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "extend-gate-reviewer-auth-selftest: FAILED $(basename "$f") (rc=$rc)" >&2
    fail_n=$((fail_n + 1))
  fi
done
shopt -u nullglob

if [ "$fail_n" -eq 0 ]; then
  echo "extend-gate-reviewer-auth-selftest: PASS (0 FAIL)"
  exit 0
else
  echo "extend-gate-reviewer-auth-selftest: FAIL ($fail_n FAIL)" >&2
  exit 1
fi
