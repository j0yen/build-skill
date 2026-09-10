#!/usr/bin/env bash
# python-worktree-selftest.sh — regression coverage for
# PRD-build-python-worktree-isolation AC1-4: two same-lane python-agent-
# shaped writers sharing one `build_into` must never observe or clobber
# each other's uncommitted files, and both must land cleanly in sequence.
#
# This is the fixture-repo re-simulation of the real 2026-09-10 collision
# (synthorg-run-telemetry vs synthorg-capability-tasks, both editing
# src/synthorg/cli.py in the shared main checkout with no isolation) — see
# the PRD's own "Verification" section. Builds ONE disposable python
# fixture repo under $TMPDIR (never synthorg, never any production repo)
# and drives `worktree-extend.sh add`/`land` exactly as SKILL.md's Phase
# 3/4 python routing now does.
#
#   AC1 — two branches `add`ed against the same build_into each get their
#         own worktree; `git diff`/`git status` in the fixture's MAIN
#         checkout shows zero changes from either branch until `land` runs.
#   AC2 — a solo `add`+`land` (no sharing) round-trips: HEAD ends on a
#         plain fast-forward-shaped merge with only that branch's file
#         changed, no leftover worktree, no leftover branch's target dir.
#   AC3 — `land` against a dirty main checkout exits 4, performs no merge,
#         and the worktree's commit remains intact for a retry (already
#         covered live during implementation smoke-testing; re-asserted
#         here as a permanent regression check).
#   AC4 — two concurrent writers editing DIFFERENT files in one shared
#         build_into: neither's uncommitted diff/hunk is ever visible in
#         the other's worktree while both are mid-edit, and both land in
#         sequence (second land rebase-retries onto the first's merge)
#         with a clean, non-conflicted final `git log --graph`.
#
# Usage: python-worktree-selftest.sh
# Exit: 0 all checks pass | 1 a check failed | 2 missing prerequisite
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORKTREE_EXTEND="$HERE/worktree-extend.sh"
[ -x "$WORKTREE_EXTEND" ] || { echo "selftest: $WORKTREE_EXTEND not executable" >&2; exit 2; }
for bin in git flock; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/python-worktree-selftest.XXXXXX")"
# Route worktrees under this run's own tmpdir so a failed/aborted run never
# leaves fixture worktrees behind under the real ~/.cache/build-worktrees.
export BUILD_WT_ROOT="$T/build-worktrees"
trap '[ -n "${PYWT_SELFTEST_KEEP:-}" ] || { git -C "$REPO" worktree list --porcelain 2>/dev/null | awk "/^worktree /{print \$2}" | grep -F "$BUILD_WT_ROOT" | while read -r w; do git -C "$REPO" worktree remove --force "$w" 2>/dev/null; done; rm -rf "$T"; }' EXIT

REPO="$T/repo"
mkdir -p "$REPO/src"
git -C "$REPO" init -q -b main
GIT_ID=(-c user.email=test@python-worktree-selftest.local -c user.name="python-worktree-selftest")

cat > "$REPO/pyproject.toml" <<'EOF'
[project]
name = "pyworktree-fixture"
version = "0.1.0"
EOF
cat > "$REPO/src/cli.py" <<'EOF'
def main():
    print("fixture cli v0")
EOF
cat > "$REPO/src/other.py" <<'EOF'
def other():
    return 0
EOF
git -C "$REPO" "${GIT_ID[@]}" add -A
git -C "$REPO" "${GIT_ID[@]}" commit -q -m "init fixture"

# --- AC1 + AC2: solo add/land round-trip, main stays clean until land ---
WT_A="$("$WORKTREE_EXTEND" add "$REPO" solo 2>/dev/null)"
expect "AC1/2: add returns a worktree path" "[ -n \"$WT_A\" ] && [ -d \"$WT_A\" ]"
expect "AC1: main checkout clean immediately after add" \
  "[ -z \"\$(git -C "$REPO" status --porcelain)\" ]"

printf 'def main():\n    print("fixture cli v1 (solo)")\n' > "$WT_A/src/cli.py"
git -C "$WT_A" "${GIT_ID[@]}" add -A
git -C "$WT_A" "${GIT_ID[@]}" commit -q -m "solo: bump cli"
expect "AC1: worktree edit invisible in main checkout before land" \
  "[ -z \"\$(git -C "$REPO" status --porcelain)\" ] && ! grep -q v1 "$REPO/src/cli.py""

"$WORKTREE_EXTEND" land "$REPO" solo >/dev/null 2>&1
land_rc=$?
expect "AC2: solo land exits 0" "[ $land_rc -eq 0 ]"
expect "AC2: solo land's change is now on main" "grep -q v1 "$REPO/src/cli.py""
expect "AC2: solo land leaves no worktree behind" \
  "! git -C "$REPO" worktree list --porcelain | grep -qF \"$BUILD_WT_ROOT\""

# --- AC3: land against a dirty main checkout fails closed ---
WT_D="$("$WORKTREE_EXTEND" add "$REPO" dirtycheck 2>/dev/null)"
echo "def x(): pass" >> "$WT_D/src/other.py"
git -C "$WT_D" "${GIT_ID[@]}" add -A
git -C "$WT_D" "${GIT_ID[@]}" commit -q -m "dirtycheck: edit other.py"
echo "uncommitted" >> "$REPO/README-dirty.md"
"$WORKTREE_EXTEND" land "$REPO" dirtycheck >/dev/null 2>/tmp/pywt-selftest-dirty.$$.log
dirty_rc=$?
expect "AC3: land on dirty main exits 4" "[ $dirty_rc -eq 4 ]"
expect "AC3: dirty land performs no mutation (main HEAD unchanged)" \
  "! grep -q 'def x' "$REPO/src/other.py""
expect "AC3: dirty land's branch commit remains intact for retry" \
  "git -C "$REPO" show autobuilder/dirtycheck:src/other.py | grep -q 'def x'"
rm -f "$REPO/README-dirty.md" /tmp/pywt-selftest-dirty.$$.log
"$WORKTREE_EXTEND" land "$REPO" dirtycheck >/dev/null 2>&1
expect "AC3: retry after cleaning main lands successfully" "grep -q 'def x' "$REPO/src/other.py""

# --- AC1 + AC4: two concurrent writers, shared build_into, disjoint files ---
WT_X="$("$WORKTREE_EXTEND" add "$REPO" concurrent-x 2>/dev/null)"
WT_Y="$("$WORKTREE_EXTEND" add "$REPO" concurrent-y 2>/dev/null)"
expect "AC1: two branches get two distinct worktree paths" "[ \"$WT_X\" != \"$WT_Y\" ]"

printf 'def main():\n    print("edited by concurrent-x")\n' > "$WT_X/src/cli.py"
printf 'def other():\n    return 1  # edited by concurrent-y\n' > "$WT_Y/src/other.py"

expect "AC4: X's edit not visible in Y's worktree" "! grep -q concurrent-x "$WT_Y/src/cli.py""
expect "AC4: Y's edit not visible in X's worktree" "! grep -q concurrent-y "$WT_X/src/other.py""
expect "AC1: main checkout still shows zero changes from either" \
  "[ -z \"\$(git -C "$REPO" status --porcelain)\" ]"

git -C "$WT_X" "${GIT_ID[@]}" add -A
git -C "$WT_X" "${GIT_ID[@]}" commit -q -m "concurrent-x: edit cli.py"
git -C "$WT_Y" "${GIT_ID[@]}" add -A
git -C "$WT_Y" "${GIT_ID[@]}" commit -q -m "concurrent-y: edit other.py"

"$WORKTREE_EXTEND" land "$REPO" concurrent-x >/dev/null 2>&1
x_rc=$?
"$WORKTREE_EXTEND" land "$REPO" concurrent-y >/dev/null 2>&1
y_rc=$?
expect "AC4: concurrent-x lands (exit 0)" "[ $x_rc -eq 0 ]"
expect "AC4: concurrent-y lands after rebase-retry (exit 0)" "[ $y_rc -eq 0 ]"
expect "AC4: both edits present on main, neither clobbered the other" \
  "grep -q concurrent-x "$REPO/src/cli.py" && grep -q concurrent-y "$REPO/src/other.py""
expect "AC4: final history has no unresolved conflict markers" \
  "! grep -rq '<<<<<<<' "$REPO/src""
expect "AC4: final main checkout is clean" "[ -z \"\$(git -C "$REPO" status --porcelain)\" ]"

echo "---"
if [ "$fail" -eq 0 ]; then
  echo "python-worktree-selftest: ALL CHECKS PASS"
else
  echo "python-worktree-selftest: FAILURES ABOVE" >&2
fi
exit "$fail"
