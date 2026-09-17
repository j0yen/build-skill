#!/usr/bin/env bash
# tests/pinned_slug_common_dir.sh — decision 42f14605, regression test for
# extend-gate.sh's and branch-protection.sh's ci-checks/pr-checks slug
# resolution.
#
# Under --pinned-landing, $repo is a detached verify worktree such as
# ~/.cache/build-worktrees/mcphost-mcphost-agent-wake-verify. The old
# `_repo_slug_for_ci="$(basename "$repo")"` (extend-gate.sh) and
# `repo_slug="$(basename "$repo_dir")"` (branch-protection.sh, six call
# sites incl. cmd_pr_checks) both yielded the WORKTREE's own name there,
# not the repo slug push_via_branch_for()/the landings dir key on, so a
# pinned-landing `branch-protection.sh pr-checks` call misrouted (blocked
# mcphost-agent-wake's pinned gate with skip_reason=no-landing-record even
# though state/landings/mcphost/mcphost-agent-wake.json exists).
#
# extend-gate.sh's copy was extracted into scripts/lib/repo-slug.sh (decision
# 42f14605 extended 2026-09-17) so both scripts share exactly one resolver.
# This sources that shared lib directly (rather than running either whole
# script, which need cargo/ssh/gh stubs) and asserts it against a real git
# worktree, then asserts both call sites actually use it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$HERE/../scripts"
REPO_SLUG_LIB="$SCRIPTS_DIR/lib/repo-slug.sh"
EXTEND_GATE="$SCRIPTS_DIR/extend-gate.sh"
BRANCH_PROTECTION="$SCRIPTS_DIR/branch-protection.sh"

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

# Source the shared resolver directly — this is the exact function both
# extend-gate.sh's ci-checks phase AND branch-protection.sh's cmd_pr_checks
# (and every other repo_slug site) call, not a reimplementation of it.
[ -s "$REPO_SLUG_LIB" ] || { echo "FAIL $REPO_SLUG_LIB missing or empty" >&2; exit 1; }
# shellcheck source=../scripts/lib/repo-slug.sh
source "$REPO_SLUG_LIB"

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

# Both scripts must source the ONE shared resolver, not carry their own copy.
expect "extend-gate.sh sources lib/repo-slug.sh" \
  "grep -q 'source \"\$BUILD_SCRIPTS/lib/repo-slug.sh\"' '$EXTEND_GATE'"
expect "branch-protection.sh sources lib/repo-slug.sh" \
  "grep -q 'source \"\$HERE/lib/repo-slug.sh\"' '$BRANCH_PROTECTION'"

# branch-protection.sh: every repo_slug call site must use the shared
# resolver — this is what was broken (basename "$repo_dir" at six sites,
# incl. cmd_pr_checks, the exact call extend-gate.sh's pinned-landing
# ci-checks phase makes). Fails on the old code (0 uses, 6+ bare basename
# sites), passes on the new (>=6 uses, 0 bare basename sites).
bp_uses="$(grep -c 'repo_slug_for_ci "\$repo_dir"' "$BRANCH_PROTECTION")"
bp_bare="$(grep -c 'basename "\$repo_dir"' "$BRANCH_PROTECTION")"
expect "branch-protection.sh: all repo_slug sites use repo_slug_for_ci (found $bp_uses)" \
  "[ '$bp_uses' -ge 6 ]"
expect "branch-protection.sh: no bare basename \"\$repo_dir\" sites remain (found $bp_bare)" \
  "[ '$bp_bare' -eq 0 ]"

if [ "$fail" -ne 0 ]; then
  echo "pinned_slug_common_dir: FAIL" >&2
  exit 1
fi
echo "pinned_slug_common_dir: PASS"
