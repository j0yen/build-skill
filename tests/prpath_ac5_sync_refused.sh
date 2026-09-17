#!/usr/bin/env bash
# tests/prpath_ac5_sync_refused.sh — PRD-build-main-push-gate-pr-path AC5.
# tree-diff, dirty tracked tree, and HEAD-not-on-main each leave `main`
# untouched, journal `main-sync-refused reason=<...>`, and exit 6.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=prpath_common.sh
source "$HERE/prpath_common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prpath-ac5.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export BUILD_STATE_DIR="$ROOT/state"
export BUILD_JOURNAL_ROOT="$ROOT/journal"
mkdir -p "$BUILD_STATE_DIR"

bindir="$ROOT/bin"
prpath_install_gh_stub "$bindir"
export PATH="$bindir:$PATH"

mkdir -p "$BUILD_JOURNAL_ROOT"
journal_file() { echo "$BUILD_JOURNAL_ROOT/$(date -u +%F).md"; }

# --- case A: tree-diff (main advanced AND diverged with a DIFFERENT tree) -
work_a="$(prpath_mk_repo "$ROOT/repo-a")"
(
  cd "$work_a"
  echo "local-only-change" >> file.txt
  git commit -qam "local change"
)
old_a="$(git -C "$work_a" rev-parse main)"
other_a="$ROOT/other-a"
git clone -q "$ROOT/repo-a/origin.git" "$other_a"
(
  cd "$other_a"
  git config user.name "Fixture Bot"; git config user.email "fixture@example.invalid"
  echo "different-remote-change" >> file.txt
  git commit -qam "remote change"
  git push -q origin main
)
: > "$(journal_file)"

out_a="$("$PRPATH_BP" sync "$work_a" 2>&1)"
rc_a=$?
prpath_expect "AC5 tree-diff: exits 6" '[ "$rc_a" -eq 6 ]'
prpath_expect "AC5 tree-diff: main untouched" '[ "$(git -C "$work_a" rev-parse main)" = "$old_a" ]'
prpath_expect "AC5 tree-diff: journal has main-sync-refused reason=tree-diff" \
  'grep -q "main-sync-refused reason=tree-diff" "$(journal_file)"'

# --- case B: dirty tracked tree (origin advanced, ff-only would work, but
#     a tracked local edit is uncommitted) --------------------------------
work_b="$(prpath_mk_repo "$ROOT/repo-b")"
other_b="$ROOT/other-b"
git clone -q "$ROOT/repo-b/origin.git" "$other_b"
(
  cd "$other_b"
  git config user.name "Fixture Bot"; git config user.email "fixture@example.invalid"
  echo "remote-advance" >> file.txt
  git commit -qam "remote advance"
  git push -q origin main
)
echo "dirty-uncommitted" >> "$work_b/file.txt"
old_b="$(git -C "$work_b" rev-parse main)"
: > "$(journal_file)"

out_b="$("$PRPATH_BP" sync "$work_b" 2>&1)"
rc_b=$?
prpath_expect "AC5 dirty: exits 6" '[ "$rc_b" -eq 6 ]'
prpath_expect "AC5 dirty: main untouched" '[ "$(git -C "$work_b" rev-parse main)" = "$old_b" ]'
prpath_expect "AC5 dirty: journal has main-sync-refused reason=dirty" \
  'grep -q "main-sync-refused reason=dirty" "$(journal_file)"'

# --- case C: HEAD not on main --------------------------------------------
work_c="$(prpath_mk_repo "$ROOT/repo-c")"
git -C "$work_c" checkout -qb other-branch
old_c="$(git -C "$work_c" rev-parse HEAD)"
: > "$(journal_file)"

out_c="$("$PRPATH_BP" sync "$work_c" 2>&1)"
rc_c=$?
prpath_expect "AC5 not-on-main: exits 6" '[ "$rc_c" -eq 6 ]'
prpath_expect "AC5 not-on-main: main untouched" '[ "$(git -C "$work_c" rev-parse main)" = "$old_c" ]'
prpath_expect "AC5 not-on-main: journal has main-sync-refused reason=not-on-main" \
  'grep -q "main-sync-refused reason=not-on-main" "$(journal_file)"'

exit "$prpath_fail"
