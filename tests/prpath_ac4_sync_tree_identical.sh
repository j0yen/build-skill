#!/usr/bin/env bash
# tests/prpath_ac4_sync_tree_identical.sh — PRD-build-main-push-gate-pr-path
# AC4. Given local main at L (commits ahead, unpushed) and origin/main at
# squash sha M with L^{tree} == M^{tree} (the exact 2026-09-16 gate-debt
# shape: local main diverged from a squash-merged PR whose final tree
# matches), `sync` re-points main at M, journals
# `main-synced old=L new=M tree=identical`, never uses --force/reset
# --hard, and L stays reachable from `git reflog main`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=prpath_common.sh
source "$HERE/prpath_common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prpath-ac4.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export BUILD_STATE_DIR="$ROOT/state"
export BUILD_JOURNAL_ROOT="$ROOT/journal"
mkdir -p "$BUILD_STATE_DIR"

# gh is never called by `sync`, but branch-protection.sh's top-of-file
# precondition (`gh auth status`) still runs -- stub it so this test has
# no real network/auth dependency.
bindir="$ROOT/bin"
prpath_install_gh_stub "$bindir"
export PATH="$bindir:$PATH"

work="$(prpath_mk_repo "$ROOT/repo")"

# Two local-only commits on `work` (never pushed) -- simulates "18 commits
# ahead" (any N >= 1 exercises the same divergence).
(
  cd "$work"
  echo "two" >> file.txt
  git commit -qam "add two"
  echo "three" >> file.txt
  git commit -qam "add three"
)
old_sha="$(git -C "$work" rev-parse main)"

# A second clone lands the "PR", squashed into ONE commit with the SAME
# final tree as work's two local commits, and pushes it to origin/main --
# exactly what GitHub's squash-merge does to a branch whose PR carried
# more than one commit.
other="$ROOT/other"
git clone -q "$ROOT/repo/origin.git" "$other"
(
  cd "$other"
  git config user.name "Fixture Bot"
  git config user.email "fixture@example.invalid"
  echo "two" >> file.txt
  echo "three" >> file.txt
  git commit -qam "squash: add two + three"
  git push -q origin main
)
new_sha="$(git -C "$other" rev-parse main)"

prpath_expect "AC4 setup: work and origin diverged onto different shas" '[ "$old_sha" != "$new_sha" ]'
prpath_expect "AC4 setup: trees are identical" \
  '[ "$(git -C "$work" rev-parse main^{tree})" = "$(git -C "$other" rev-parse main^{tree})" ]'

out="$("$PRPATH_BP" sync "$work" 2>&1)"
rc=$?

prpath_expect "AC4: sync exits 0" '[ "$rc" -eq 0 ]'
prpath_expect "AC4: main now points at the squash sha M" '[ "$(git -C "$work" rev-parse main)" = "$new_sha" ]'
prpath_expect "AC4: L still reachable from git reflog main" '[ "$(git -C "$work" rev-parse main@{1})" = "$old_sha" ]'

journal_file="$BUILD_JOURNAL_ROOT/$(date -u +%F).md"
prpath_expect "AC4: journal has main-synced tree=identical" \
  'grep -q "main-synced old=$old_sha new=$new_sha tree=identical" "$journal_file"'

exit "$prpath_fail"
