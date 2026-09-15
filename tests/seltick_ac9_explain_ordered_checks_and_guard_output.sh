#!/usr/bin/env bash
# seltick_ac9_explain_ordered_checks_and_guard_output.sh —
# PRD-build-select-tick-deterministic AC9: given AC2's fixture, when
# `select-tick.sh --explain <one skipped slug>` runs, then it prints the
# passed checks in order and the failing check's guard output verbatim.
#
# select-tick-selftest.sh's own "AC9 smoke" case only exercises the
# admitted-slug path; this file is the standalone tests/seltick_ac9_*
# fixture the PRD's test_prefix convention calls for, and it covers the
# actual AC9 wording: a SKIPPED slug, ordered passed checks, and the
# guard's own output verbatim (not just a smoke check on the happy path).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seltick-common.sh"
seltick_setup

# AC2's fixture: 8 rust-extend PRDs on one build_into, BUILD_DISTINCT_TARGETS=1
# so all but the first are skipped same-target -- the guard's own reject
# line (e.g. "same-target: ...") is what --explain must echo verbatim.
for i in 1 2 3 4 5 6 7 8; do
  seltick_write_prd "rext$i" rust-extend /tmp/seltick-ac9-shared-repo
done
FAKE_BURST_READY=true
FAKE_BURST_WIDTH=8

explain_out=$(BUILD_DISTINCT_TARGETS=1 BUILD_MAX_BRANCHES=30 seltick_run --explain rext2 2>&1)

lines=()
while IFS= read -r l; do lines+=("$l"); done <<<"$explain_out"

fail() { echo "FAIL AC9: $*" >&2; echo "--- full --explain output ---" >&2; printf '%s\n' "$explain_out" >&2; exit 1; }

[ "${lines[0]:-}" = "explain: rext2" ] || fail "expected header 'explain: rext2', got '${lines[0]:-}'"
[ "${lines[1]:-}" = "passed: scan" ] || fail "expected ordered check 1 'passed: scan', got '${lines[1]:-}'"
[ "${lines[2]:-}" = "passed: hard-prefilter" ] || fail "expected ordered check 2 'passed: hard-prefilter', got '${lines[2]:-}'"
[ "${lines[3]:-}" = "passed: depends-on" ] || fail "expected ordered check 3 'passed: depends-on', got '${lines[3]:-}'"

guard_line="${lines[4]:-}"
case "$guard_line" in
  "guard (first failure): "*) ;;
  *) fail "expected the 4th line to be the guard's own first-failure output verbatim, got '$guard_line'" ;;
esac
case "$guard_line" in
  *"same-target"*) ;;
  *) fail "expected the guard's verbatim output to name same-target (this is a same-target skip), got '$guard_line'" ;;
esac

[ "${lines[5]:-}" = "result: skipped" ] || fail "expected the final line 'result: skipped', got '${lines[5]:-}'"

echo "ok  AC9: --explain on a skipped slug prints ordered passed checks then the guard's own verbatim rejection and result"
