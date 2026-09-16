#!/usr/bin/env bash
# routepar-selftest.sh — the one entrypoint for PRD-build-gate-route-
# parity-ledger's fixture coverage (test_prefix: routepar). Runs every
# tests/routepar_ac*.sh: ac1/ac2/ac4/ac5 drive the REAL extend-gate.sh
# through the fake toolchain at tests/fixtures/routepar-fake/ against a
# disposable fixture crate (never mcphost, never any production repo);
# ac3/ac6/ac7 are pure journal/function fixtures, no live gate, fast.
#
# Usage: routepar-selftest.sh
#
# Exit: 0 all green | 1 one or more failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

fail=0
shopt -s nullglob
for f in "$SKILL_DIR"/tests/routepar_ac*.sh; do
  echo "== routepar-selftest: $(basename "$f") ==" >&2
  bash "$f"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "routepar-selftest: FAILED $(basename "$f") (rc=$rc)" >&2
    fail=1
  fi
done
shopt -u nullglob

if [ "$fail" -eq 0 ]; then
  echo "routepar-selftest: all green"
else
  echo "routepar-selftest: one or more failures — see above" >&2
fi
exit "$fail"
