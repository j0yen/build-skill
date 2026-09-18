#!/usr/bin/env bash
# tests/canary_ac16_same_target_cap_unbounded.sh —
# PRD-build-burst-gate-canary-invariant R14/AC16.
#
# AC16's assertions live in scripts/select-guard-same-target-cap-selftest.sh
# (sections AC16a/AC16b), next to the AC9 cap cases they extend and next to
# the fake burst-lane.sh convention they share: splitting them out would have
# meant a second copy of that fixture. That file's name does not fit the
# `<test_prefix>_ac<N>_` convention verified-completed.sh --derive pairs ACs
# by, so AC16 derived as MISSING (2026-09-18) even though it was covered and
# wired into run-selftests.sh --all. This wrapper is the pairing surface: it
# RUNS the real suite (no re-assertion of its logic, no duplicated fixture)
# and fails unless every AC16 label the suite is supposed to print came back
# `ok`, so a silently renamed or deleted AC16 section fails here rather than
# passing by absence.
#
# Pure fixture: the underlying suite fakes burst-lane.sh status entirely —
# no box, no hcloud, no network, no cargo.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SUITE="$HERE/../scripts/select-guard-same-target-cap-selftest.sh"
[ -x "$SUITE" ] || { echo "canary_ac16: $SUITE missing or not executable" >&2; exit 2; }

out="$("$SUITE" 2>&1)"; rc=$?

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi; }

expect "AC16: select-guard-same-target-cap-selftest.sh exits 0" "[ $rc -eq 0 ]"

# AC16a — gate_ready=true with neither `width` nor `run_slots.cap`: exactly
# one admitted, the rest blocked cause=cap-unbounded-under-burst, summary
# carries cap_source=blocked.
expect "AC16a: exactly one of five admitted (fail closed, not unbounded)" \
  "printf '%s' \"\$out\" | grep -qF 'ok  AC16a: exactly one of five admitted'"
expect "AC16a: diagnostic reads cap=1 source=blocked cap_source=blocked" \
  "printf '%s' \"\$out\" | grep -qF 'ok  AC16a: diagnostic reads cap=1 source=blocked cap_source=blocked'"
expect "AC16a: blocked candidate names cause=cap-unbounded-under-burst" \
  "printf '%s' \"\$out\" | grep -qE 'ok  AC16a: second candidate.* names cause=cap-unbounded-under-burst'"
expect "AC16a: journal has same-target-blocked cause=cap-unbounded-under-burst" \
  "printf '%s' \"\$out\" | grep -qF 'ok  AC16a: journal has same-target-blocked cause=cap-unbounded-under-burst'"

# AC16b — regression guard: run_slots.cap=4 present, four admitted, cap=4
# source=burst (the block must not swallow a resolvable cap).
expect "AC16b: four of five admitted with run_slots.cap=4" \
  "printf '%s' \"\$out\" | grep -qF 'ok  AC16b: four of five admitted'"
expect "AC16b: diagnostic reads cap=4 source=burst" \
  "printf '%s' \"\$out\" | grep -qF 'ok  AC16b: diagnostic reads cap=4 source=burst'"

expect "AC16: underlying suite reported ALL PASS" \
  "printf '%s' \"\$out\" | grep -qF 'select-guard-same-target-cap-selftest: ALL PASS'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canary_ac16_same_target_cap_unbounded: ALL PASS"
  exit 0
fi
echo "canary_ac16_same_target_cap_unbounded: assertion(s) FAILED" >&2
printf '%s\n' "$out" | tail -40 >&2
exit 1
