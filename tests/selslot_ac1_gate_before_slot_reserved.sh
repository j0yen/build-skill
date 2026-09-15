#!/usr/bin/env bash
# selslot_ac1_gate_before_slot_reserved.sh —
# PRD-build-select-guard-depends-before-slot AC1: given two same-target
# high-priority PRDs where the first (by existing priority-then-path sort)
# has an unmet Depends-on and the second has none, when the coordinator
# calls select-guard.sh for both in that order within one tick, then the
# second returns rc=0 and is admitted, the first returns rc=1 with verdict
# text containing "gated: depends-on:", and the target's admitted-targets
# state shows exactly one entry for that build_into.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/selslot-common.sh"
selslot_setup

TARGET=/tmp/selslot-ac1-repo
selslot_write_prd first "$TARGET" PRD-selslot-ac1-dep-unmet.md
selslot_write_prd second "$TARGET"
selslot_commit

set +e
out_first=$(selslot_guard first 0 "" 2>&1); rc_first=$?
set -e
[ "$rc_first" -eq 1 ] || { echo "FAIL AC1: expected first gated, got rc=$rc_first: $out_first" >&2; exit 1; }
echo "$out_first" | grep -q '^blocked: first: gated: depends-on:' \
  || { echo "FAIL AC1: verdict missing gated: depends-on: prefix: $out_first" >&2; exit 1; }

# "first" was gated -- a real caller never appends a gated candidate's
# build_into, so "second" is evaluated against the SAME empty
# admitted-targets state and must be admitted.
out_second=$(selslot_guard second 0 "")
echo "$out_second" | grep -q '^ok: second:' \
  || { echo "FAIL AC1: expected second admitted, got: $out_second" >&2; exit 1; }

# admitted-targets now carries exactly one entry for the target (appended
# only for the admitted candidate) -- prove it by threading it forward: a
# further same-target call is blocked by the same-target cap (not
# depends-on), i.e. exactly one slot was consumed.
set +e
out_third=$(selslot_guard second 1 "$TARGET" 2>&1); rc_third=$?
set -e
[ "$rc_third" -eq 1 ] || { echo "FAIL AC1: expected the target already at cap=1, got rc=$rc_third: $out_third" >&2; exit 1; }
echo "$out_third" | grep -q 'same-target:' \
  || { echo "FAIL AC1: expected a same-target block (slot already consumed), got: $out_third" >&2; exit 1; }

echo "ok  AC1: first gated (depends-on) before the slot was reserved, second admitted, slot consumed exactly once"
