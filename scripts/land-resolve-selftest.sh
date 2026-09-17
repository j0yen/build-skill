#!/usr/bin/env bash
# land-resolve-selftest.sh — the one entrypoint for PRD-build-land-
# conflict-resolver's fixture coverage (R7, test_prefix: landres).
#
# Runs every tests/landres_ac*.sh:
#   AC1  — pre-gate rebase (R1): gate-then-land.sh rebases onto main's
#          current tip BEFORE the branch gate; a generated-file conflict
#          resolves and lands, a source-file conflict aborts BEFORE any
#          gate attempt is ever printed.
#   AC2  — classify + resolve slices for a policy-listed generated file:
#          regen command runs once, landed file equals its output, no
#          conflict recorded as class source.
#   AC3  — classify + resolve slices for a policy-listed append-only
#          file: union merge, both sides' lines present.
#   AC4  — R4's bounded coder resolve, success path: a stub coder resolves
#          the markers, the repo's own test command then passes, the
#          rebase continues, the ledger records source/coder with a
#          numeric wall_seconds.
#   AC5  — R4's bounded coder resolve, failure path (both a stub coder
#          that exits non-zero and one that exceeds LAND_RESOLVE_MAX_S):
#          the branch is left byte-identical to its pre-resolve state,
#          the ledger records source/unresolved. A second file
#          (landres_ac5_ledger_regen_and_union.sh) covers R5's ledger
#          contract directly (one record per resolved file, right
#          class/resolution/slug/repo) plus land-conflicts-report.sh's
#          frequency ordering — R7's requirement (g).
#   AC6  — classify + resolve slices for a repo with NO policy file: every
#          path classifies source, a resolve leaves the conflict
#          untouched (no coder attempted, no `coder=unresolved` marker) —
#          R7's requirement (f), "missing policy -> old behavior".
#
# R7's requirement (e) (pre-gate rebase moves the gate base to main's
# tip) is AC1's own Scenario A/B, not a separate fixture. Requirement (g)
# (ledger has one record per event with the right classes) is covered by
# AC4/AC5's own ledger assertions plus landres_ac5_ledger_regen_and_union.sh.
#
# Usage: land-resolve-selftest.sh
#
# Exit: 0 all green | 1 one or more failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

command -v jq >/dev/null 2>&1 || { echo "land-resolve-selftest: FAIL jq not on \$PATH (required by every landres_ac*.sh fixture)" >&2; exit 1; }

fail_n=0
ran_n=0
shopt -s nullglob
for f in "$SKILL_DIR"/tests/landres_ac*.sh; do
  ran_n=$((ran_n + 1))
  echo "== land-resolve-selftest: $(basename "$f") ==" >&2
  bash "$f"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "land-resolve-selftest: FAILED $(basename "$f") (rc=$rc)" >&2
    fail_n=$((fail_n + 1))
  fi
done
shopt -u nullglob

if [ "$ran_n" -eq 0 ]; then
  echo "land-resolve-selftest: FAIL no tests/landres_ac*.sh fixtures found" >&2
  exit 1
fi

if [ "$fail_n" -eq 0 ]; then
  echo "land-resolve-selftest: PASS (0 FAIL, $ran_n fixtures)"
  exit 0
else
  echo "land-resolve-selftest: FAIL ($fail_n FAIL of $ran_n fixtures)" >&2
  exit 1
fi
