#!/usr/bin/env bash
# tests/pinned_slug_common_dir.sh — decision 42f14605, regression test for
# extend-gate.sh's ci-checks slug resolution.
#
# Under --pinned-landing, $repo is a detached verify worktree such as
# ~/.cache/build-worktrees/mcphost-mcphost-agent-wake-verify. The old
# `_repo_slug_for_ci="$(basename "$repo")"` yielded the WORKTREE's own name
# there, not the repo slug push_via_branch_for() keys on, so pinned-landing
# ci-checks misrouted (blocked mcphost-agent-wake's pinned gate at e70af61).
#
# This extracts just the repo_slug_for_ci() function out of extend-gate.sh
# (rather than running the whole gate, which needs cargo/ssh/gh stubs) and
# asserts it against a real git worktree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXTEND_GATE="$HERE/../scripts/extend-gate.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/pinned-slug-common-dir.XXXXXX")"
cleanup() { [ -n "${PINNEDSLUG_KEEP:-}" ] || rm -rf "$T"; }
trap cleanup EXIT

REPO="$T/mcphost"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=f@x -c user.name=f commit -q --allow-empty -m init

WT="$T/mcphost-mcphost-agent-wake-verify"
git -C "$REPO" worktree add -q --detach "$WT" >/dev/null 2>&1

# Extract just repo_slug_for_ci() out of the real script and source it —
# this is the exact function extend-gate.sh's ci-checks phase calls, not a
# reimplementation of it.
FN="$T/repo_slug_for_ci.sh"
sed -n '/^repo_slug_for_ci() {/,/^}/p' "$EXTEND_GATE" > "$FN"
[ -s "$FN" ] || { echo "FAIL could not extract repo_slug_for_ci() from $EXTEND_GATE" >&2; exit 1; }
source "$FN"

got_wt="$(repo_slug_for_ci "$WT")"
got_main="$(repo_slug_for_ci "$REPO")"

expect "resolver returns 'mcphost' from the detached verify worktree path" \
  "[ '$got_wt' = 'mcphost' ]"
expect "resolver returns 'mcphost' from the main repo path" \
  "[ '$got_main' = 'mcphost' ]"

# The defect this regresses: plain basename of the worktree path is NOT
# the repo slug — confirms the fixture actually exercises the bug.
expect "fixture precondition: basename(worktree) != mcphost (would false-pass otherwise)" \
  "[ '$(basename "$WT")' != 'mcphost' ]"

if [ "$fail" -ne 0 ]; then
  echo "pinned_slug_common_dir: FAIL" >&2
  exit 1
fi
echo "pinned_slug_common_dir: PASS"
