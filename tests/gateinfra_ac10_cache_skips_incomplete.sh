#!/usr/bin/env bash
# tests/gateinfra_ac10_cache_skips_incomplete.sh — PRD-build-gate-infra-
# outcome AC10 (P1, test_prefix gateinfra). Given an `incomplete` result
# at tree T, When the verdict-tree cache is consulted for T on the next
# run, Then it reports no cached verdict and the gate runs again — a
# cached incomplete means a phase never actually ran (quota limit, a
# missing binary), not that the tree is known green or known red, so
# replaying it would keep reporting a stale incomplete even after the
# cause clears.
#
# Real extend-gate.sh + the same fake toolchain reviewer-receipt-
# selftest.sh/gateinfra_ac1to3 already use: run once for real to get a
# genuine incomplete verdict cached (tree_sha/script_sha256 computed from
# the real files on disk), then run again with the SAME infra condition
# still armed and confirm the second run did NOT read `(cached)` — the
# producers actually ran a second time.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/rvrcpt-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gateinfra-ac10.XXXXXX")"
[ -n "${GATEINFRA_KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
REPO="$T/repo"
rvrcpt_write_fixture_crate "$REPO"
JOURNAL="$T/journal.md"
: > "$JOURNAL"

export FAKE_REVCLAUDE_RC=1   # reviewer infra, stays armed for BOTH runs
export FAKE_GH_AUTH_RC=0     # isolate to the reviewer phase alone

echo "=== run 1: real producer sequence, ends incomplete, caches it ==="
out_1="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc_1=$?
cache_file="$REPO/target/autobuilder/last-verdict.json"
expect "run 1: exit code is 9 (incomplete)" "[ $rc_1 -eq 9 ]"
expect "run 1: cache file was written with verdict=incomplete" \
  "[ -f '$cache_file' ] && [ \"\$(jq -r '.verdict' '$cache_file')\" = incomplete ]"
expect "run 1: producers actually ran (no '(cached)' on a first run)" \
  "[[ \"\$out_1\" != *'(cached)'* ]]"

echo "=== run 2: same tree, same script — a normal cache WOULD hit, but R10 forbids it for incomplete ==="
out_2="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc_2=$?
unset FAKE_REVCLAUDE_RC FAKE_GH_AUTH_RC
expect "run 2: exit code is STILL 9 (re-ran, reached the same real conclusion)" "[ $rc_2 -eq 9 ]"
expect "run 2: never read '(cached)' — R10, the cache is skipped for an incomplete entry" \
  "[[ \"\$out_2\" != *'(cached)'* ]]"
expect "run 2: the reviewer phase actually ran again (fresh infra note in the log)" \
  "[[ \"\$out_2\" == *'claude -p subagent invocation failed'* ]]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "gateinfra_ac10: ALL PASS"
else
  echo "gateinfra_ac10: assertion(s) FAILED"
fi
exit "$fail"
