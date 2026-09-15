#!/usr/bin/env bash
# sccache_guard_remote_cmd.sh — PRD-build-gate-wall-clock requirement 2,
# burst-lane.sh's remote-box leg (2026-09-15 "busy is not dead" fix).
#
# The cheapest path to prove this: burst-lane.sh's `main` only runs when
# the file is EXECUTED (`[ "${BASH_SOURCE[0]}" = "${0}" ]` at the bottom),
# so sourcing it is side-effect-free (pure variable assignment + one
# `command -v jq` at the top level — no ssh, no hcloud, no network) and
# hands us `remote_sccache_guard()` and `$REMOTE_SCCACHE_DIR` directly,
# with no need for the full fake-ssh/fake-hcloud fixture
# scripts/burst-lane-selftest.sh drives (a 10+ minute monolith — see that
# script's own header). BURST_LANE_STATE_DIR is pinned to a throwaway
# tmpdir purely so a stray `state/` write can't land in the real skill
# tree; nothing here calls a function that writes to it.
#
# NOTE: checks below use plain `if [[ ... ]]` per assertion rather than the
# usual eval-a-condition-string `expect()` helper other selftests use —
# $out (the guard text) itself contains `$`/`"` shell metacharacters, and
# building an eval'd condition string by interpolating $out into it would
# hand those characters to a SECOND round of shell parsing (bit us once
# already while drafting this file: "ok: unbound variable" from the
# guard's own embedded `$ok`).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"
[ -f "$BL" ] || { echo "selftest: $BL not found" >&2; exit 2; }

fail=0
ok()  { echo "ok  $1"; }
bad() { echo "FAIL $1" >&2; fail=1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/sccache-guard-remote-cmd.XXXXXX")"
trap 'rm -rf "$T"' EXIT

out="$(BURST_LANE_STATE_DIR="$T/state" bash -c '
  source "'"$BL"'"
  remote_sccache_guard
')"
rc=$?

if [ "$rc" -eq 0 ] && [ -n "$out" ]; then ok "guard sources cleanly and prints a snippet"
else bad "guard sources cleanly and prints a snippet (rc=$rc)"; fi

if [[ "$out" == *'pgrep -x sccache'* ]]; then ok "guard checks for a live server before doing anything"
else bad "guard checks for a live server before doing anything"; fi

if [[ "$out" != *'--stop-server'* ]]; then ok "guard never calls --stop-server"
else bad "guard never calls --stop-server"; fi

if [[ "$out" == *'timeout 30 sccache --show-stats'* ]]; then ok "guard uses the raised 30s answer window"
else bad "guard uses the raised 30s answer window"; fi

if [[ "$out" == *'seq 1 60'* ]]; then ok "guard polls up to 60s before giving up"
else bad "guard polls up to 60s before giving up"; fi

if [[ "$out" == *'burst-lane: sccache_unreachable on remote box'* ]] && [[ "$out" == *'exit 97'* ]]; then
  ok "guard keeps the existing unreachable message/exit 97"
else
  bad "guard keeps the existing unreachable message/exit 97"
fi

if [[ "$out" == *'flock -x'*'.guard.lock sccache --start-server'* ]]; then
  ok "guard serializes the one allowed start under flock"
else
  bad "guard serializes the one allowed start under flock"
fi

# The IDLE_TIMEOUT export lives on cmd_run's own $remote_cmd line (the
# export list alongside the other SCCACHE_ vars), not inside the guard
# snippet itself — assert it's present there rather than in $out above.
if grep -qF 'SCCACHE_CACHE_SIZE=${BURST_SCCACHE_GB}G SCCACHE_IDLE_TIMEOUT=0' "$BL"; then
  ok "cmd_run exports SCCACHE_IDLE_TIMEOUT=0 alongside the other SCCACHE_ vars"
else
  bad "cmd_run exports SCCACHE_IDLE_TIMEOUT=0 alongside the other SCCACHE_ vars"
fi

if [ "$fail" -eq 0 ]; then
  echo "sccache-guard-remote-cmd: all cases passed"
else
  echo "sccache-guard-remote-cmd: FAILURES ABOVE" >&2
fi
exit "$fail"
