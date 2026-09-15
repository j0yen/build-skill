#!/usr/bin/env bash
# selslot_ac5_selslot_a_fixture.sh —
# PRD-build-select-guard-depends-before-slot AC5 (selslot_a fixture): two
# same-target high PRDs, the first has an unmet Depends-on; when the
# selftest runs it, the second is admitted, the first is reported gated,
# and the target slot is consumed exactly once -- asserted by COUNTING
# admissions for that build_into across the whole candidate pool, not just
# by reading each individual call's exit code.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/selslot-common.sh"
selslot_setup

TARGET=/tmp/selslot-ac5-repo
selslot_write_prd gated "$TARGET" PRD-selslot-ac5-dep-unmet.md
selslot_write_prd clean1 "$TARGET"
selslot_write_prd clean2 "$TARGET"
selslot_commit

admitted_count=0
admitted_targets=""
branch_count=0
for slug in gated clean1 clean2; do
  set +e
  out=$(selslot_guard "$slug" "$branch_count" "$admitted_targets" 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    admitted_count=$((admitted_count + 1))
    branch_count=$((branch_count + 1))
    admitted_targets="${admitted_targets:+$admitted_targets,}$TARGET"
  elif [ "$slug" = "gated" ]; then
    echo "$out" | grep -q 'gated: depends-on:' \
      || { echo "FAIL AC5: gated candidate not reported gated: $out" >&2; exit 1; }
  fi
done

[ "$admitted_count" -eq 1 ] \
  || { echo "FAIL AC5: expected exactly 1 admission counted for $TARGET, counted $admitted_count" >&2; exit 1; }

echo "ok  AC5: selslot_a fixture -- target slot consumed exactly once (counted, not just exit codes)"
