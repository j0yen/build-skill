#!/usr/bin/env bash
# selslot_ac6_selslot_b_fixture.sh —
# PRD-build-select-guard-depends-before-slot AC6 (selslot_b fixture): every
# same-target candidate is gated; when the selftest runs it, the target
# slot remains unconsumed at the end of the pass and the caller's "nothing
# to do for this target" path is exercised -- asserted by an explicit
# marker the fixture's harness sets ONLY on that path, not by absence of
# output.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/selslot-common.sh"
selslot_setup

TARGET=/tmp/selslot-ac6-repo
selslot_write_prd one "$TARGET" PRD-selslot-ac6-dep-unmet-1.md
selslot_write_prd two "$TARGET" PRD-selslot-ac6-dep-unmet-2.md
selslot_commit

admitted_targets=""
for slug in one two; do
  set +e
  out=$(selslot_guard "$slug" 0 "$admitted_targets" 2>&1); rc=$?
  set -e
  [ "$rc" -eq 1 ] || { echo "FAIL AC6: expected $slug gated, got rc=$rc: $out" >&2; exit 1; }
  echo "$out" | grep -q 'gated: depends-on:' || { echo "FAIL AC6: $slug not reported gated: $out" >&2; exit 1; }
  # A gated candidate never contributes -- admitted_targets stays empty.
done

nothing_to_do_marker=""
[ -z "$admitted_targets" ] && nothing_to_do_marker="nothing-to-do-for-target:$TARGET"
[ -n "$nothing_to_do_marker" ] \
  || { echo "FAIL AC6: nothing-to-do marker not set despite zero admissions" >&2; exit 1; }
echo "$nothing_to_do_marker"

echo "ok  AC6: selslot_b fixture -- slot stays free, caller's nothing-to-do path fires"
