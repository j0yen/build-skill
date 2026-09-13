#!/usr/bin/env bash
# pullback_ac8_teardown_sweep.sh — PRD-build-burst-pull-back-restore AC8.
#
# Given two pullable worktrees and one cold worktree, When the sweep runs,
# Then both pullable worktrees have `target/` back, pulled and cold
# markers are cleared, and the cold worktree is journaled cold.
#
# Matches scripts/burst-lane-selftest.sh's "burstpull AC4" sweep block
# (~line 630). HOST CAVEAT: sweep_dirty_worktrees' own money guard
# (burst-lane.sh ~line 4993, 2026-09-11) skips every teardown pull unless
# this host's real `claude-build.path` systemd --user unit is active — a
# deliberate production guard this fixture never overrides or fakes (and
# this wrapper never starts/stops that real unit). On carbon/ryzen7 that
# unit is intentionally inactive (build lanes RedBaron-only since 09-08),
# so this AC cannot be verified here; it is expected to actually run (and
# be checked) on RedBaron.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullback-ac-common.sh"
pullback_run_suite

if ! pullback_loop_active; then
  echo "FAIL pullback AC8: cannot verify on this host — claude-build.path is inactive (carbon/ryzen7 build-lane policy, 09-08: RedBaron-only), so sweep_dirty_worktrees' money guard (burst-lane.sh ~line 4993) journals sweep-skipped(cause=loop-stopped) and never runs the pulls this AC asserts. Expected to pass on RedBaron, where the loop is active. Selftest evidence for this block:" >&2
  grep -F "burstpull AC4:" <<<"$PULLBACK_OUT" >&2 || true
  exit 1
fi

fail=0
for line in \
  "ok  burstpull AC4: the two pullable worktrees got their target/ back" \
  "ok  burstpull AC4: the cold worktree's target/ was never fetched" \
  "ok  burstpull AC4: the busy worktree's target/ was never fetched either (sweep skipped it, did not wait)" \
  "ok  burstpull AC4: the pulled/cold markers are cleared after the sweep" \
  "ok  burstpull AC4: the busy worktree's marker is LEFT dirty for a later retry (sweep does not abort on it)" \
  "ok  burstpull AC4: the cold worktree was journaled cold, not silently dropped" \
  "ok  burstpull AC4: the busy worktree's sweep failure is journaled, and the sweep continued past it" \
; do
  if grep -qF "$line" <<<"$PULLBACK_OUT"; then
    echo "$line"
  else
    echo "FAIL pullback AC8: missing/failed: $line" >&2
    fail=1
  fi
done
exit $fail
