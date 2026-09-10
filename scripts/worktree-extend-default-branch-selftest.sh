#!/usr/bin/env bash
# worktree-extend-default-branch-selftest.sh — regression coverage for
# PRD-build-worktree-default-branch (test_prefix: wtdefault).
#
# worktree-extend.sh's `add`/`land`/`integrate` used to hardcode the literal
# branch name `main` for base resolution and as the checkout+merge target.
# On 2026-09-10 that broke `synthorg` (real default branch `master`): `land`
# silently found a STALE local `main` branch left over from an earlier,
# unrelated worktree session, checked it out, and merged onto it instead of
# `master` — exit 0, no error signal, a same-session commit dropped from the
# branch that actually got pushed to `origin/master`. See the PRD's
# five-whys for the full incident writeup.
#
# This selftest builds disposable `master`-default fixture repos (real
# `origin` bare remotes, so `origin/HEAD` resolution is exercised exactly
# the way a real build_into repo would be — never any production repo) with
# a STALE local `main` already present, and proves:
#
#   AC1 — `add` bases the new worktree branch on the resolved default
#         branch's HEAD (`origin/master`), not on the stale local `main`.
#   AC2 — `land` merges onto `master`, not `main`; the stale local `main` is
#         left byte-for-byte untouched (same commit before and after).
#   AC3 — `integrate`'s equivalent checkout/merge/--ensure-main path also
#         resolves and merges onto `master`, not `main`.
#   AC4 — THIS FILE is the regression case: run with
#         WORKTREE_EXTEND=<pre-fix copy of worktree-extend.sh>, the AC1/AC2
#         checks below fail (the bug reproduces); run against the fixed
#         script (the default), they pass. See the PRD's Phase 4 journal
#         entry for the actual before/after run transcript.
#   AC5 — a full add -> commit -> land -> cleanup cycle in a FRESH
#         master-default repo (no pre-existing stale main) leaves no stray
#         local `main` branch behind.
#
# Usage: worktree-extend-default-branch-selftest.sh
#        WORKTREE_EXTEND=<path> worktree-extend-default-branch-selftest.sh
#          (point at a different worktree-extend.sh — e.g. a pre-fix copy —
#          to demonstrate AC4's fail-before/pass-after contrast)
# Exit: 0 all checks pass | 1 a check failed | 2 missing prerequisite
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORKTREE_EXTEND="${WORKTREE_EXTEND:-$HERE/worktree-extend.sh}"
[ -x "$WORKTREE_EXTEND" ] || { echo "selftest: $WORKTREE_EXTEND not executable" >&2; exit 2; }
for bin in git flock; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/wtdefault-selftest.XXXXXX")"
export BUILD_WT_ROOT="$T/build-worktrees"
GIT_ID=(-c user.email=test@wtdefault-selftest.local -c user.name="wtdefault-selftest")
trap '[ -n "${WTDEFAULT_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

# Build a disposable master-default repo with a real `origin` bare remote
# (so origin/HEAD is genuinely set, exactly like a real build_into repo —
# never main.sh's own repo, never any production clone). Returns the working
# clone's path on stdout. The clone's HEAD/origin/HEAD both resolve to
# `master`; the caller advances master and plants a stale `main` themselves.
mk_master_repo() {
  local base="$1" name="$2"
  local seed="$base/$name-seed" origin="$base/$name-origin.git" repo="$base/$name-repo"
  mkdir -p "$seed"
  git -C "$seed" init -q -b master
  printf 'seed\n' > "$seed/README.md"
  git -C "$seed" "${GIT_ID[@]}" add -A
  git -C "$seed" "${GIT_ID[@]}" commit -q -m "init on master"
  git init -q --bare -b master "$origin"
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -q origin master
  git clone -q "$origin" "$repo"
  printf '%s\n' "$repo"
}

# ── AC1 + AC2 + AC4: add/land in a master-default repo with a stale local
#    main present must resolve+operate on master, never the stale main ──────
REPO="$(mk_master_repo "$T" land)"
expect "fixture: clone's origin/HEAD resolves to master" \
  "[ \"\$(git -C "$REPO" symbolic-ref -q --short refs/remotes/origin/HEAD)\" = origin/master ]"

OLD_COMMIT="$(git -C "$REPO" rev-parse HEAD)"
# Plant the stale local `main` at the OLD commit — simulating a leftover
# from an earlier, unrelated worktree session (exactly the 2026-09-10
# incident's precondition).
git -C "$REPO" branch main "$OLD_COMMIT"

# Advance master past the stale main's commit, so the two names genuinely
# diverge (if they still coincided, a bug that silently used `main` could
# accidentally look correct).
printf 'advance\n' >> "$REPO/README.md"
git -C "$REPO" "${GIT_ID[@]}" add -A
git -C "$REPO" "${GIT_ID[@]}" commit -q -m "advance master"
git -C "$REPO" push -q origin master
NEW_COMMIT="$(git -C "$REPO" rev-parse HEAD)"
expect "fixture: stale main and master have diverged" "[ \"$OLD_COMMIT\" != \"$NEW_COMMIT\" ]"

# AC1: add's base must be master's HEAD (== origin/master), not stale main.
WT="$("$WORKTREE_EXTEND" add "$REPO" wtdefault-land 2>/dev/null)"
BASE_COMMIT="$(git -C "$WT" rev-parse HEAD 2>/dev/null || echo MISSING)"
expect "AC1: add returned a worktree" "[ -n \"$WT\" ] && [ -d \"$WT\" ]"
expect "AC1: add's base == origin/master (resolved default), not stale main" \
  "[ \"$BASE_COMMIT\" = \"\$(git -C "$REPO" rev-parse origin/master)\" ] && [ \"$BASE_COMMIT\" != \"$OLD_COMMIT\" ]"

# AC2/AC4: land must merge onto master, not the stale main.
printf 'landed via worktree\n' >> "$WT/README.md"
git -C "$WT" "${GIT_ID[@]}" add -A
git -C "$WT" "${GIT_ID[@]}" commit -q -m "wtdefault-land: edit README"
WT_COMMIT="$(git -C "$WT" rev-parse HEAD)"

"$WORKTREE_EXTEND" land "$REPO" wtdefault-land >/dev/null 2>&1
land_rc=$?
expect "AC2/AC4: land exits 0" "[ $land_rc -eq 0 ]"
expect "AC2/AC4: land's change landed on master (working tree)" \
  "grep -q 'landed via worktree' "$REPO/README.md""
expect "AC2/AC4: repo HEAD after land is on branch master (not main)" \
  "[ \"\$(git -C "$REPO" symbolic-ref -q --short HEAD)\" = master ]"

git -C "$REPO" push -q origin master
expect "AC2/AC4: worktree commit is an ancestor of origin/master after push" \
  "git -C "$REPO" merge-base --is-ancestor "$WT_COMMIT" origin/master"
expect "AC2/AC4: the stale local main is left byte-for-byte untouched" \
  "[ \"\$(git -C "$REPO" rev-parse main)\" = \"$OLD_COMMIT\" ]"
expect "AC2/AC4: stale main's content never gained the worktree's edit" \
  "! git -C "$REPO" show main:README.md | grep -q 'landed via worktree'"

# ── AC3: integrate's checkout/merge/--ensure-main path also resolves the
#    real default branch, never the stale main ─────────────────────────────
REPO3="$(mk_master_repo "$T" integrate)"
OLD3="$(git -C "$REPO3" rev-parse HEAD)"
git -C "$REPO3" branch main "$OLD3"
printf 'advance\n' >> "$REPO3/README.md"
git -C "$REPO3" "${GIT_ID[@]}" add -A
git -C "$REPO3" "${GIT_ID[@]}" commit -q -m "advance master"
git -C "$REPO3" push -q origin master

git -C "$REPO3" checkout -q -b autobuilder/wtdefault-integrate
printf 'integrated via branch\n' >> "$REPO3/OTHER.md"
git -C "$REPO3" "${GIT_ID[@]}" add -A
git -C "$REPO3" "${GIT_ID[@]}" commit -q -m "wtdefault-integrate: add OTHER.md"
INTEGRATE_COMMIT="$(git -C "$REPO3" rev-parse HEAD)"
git -C "$REPO3" checkout -q master

# No Cargo.toml in this fixture: the merge (what this AC cares about) lands
# BEFORE the version-bump step, so integrate may still exit non-zero at the
# bump-version call against the real extend-handler.sh (no Cargo.toml to
# bump) — same tolerance cli-register-selftest.sh's AC3/AC4 already use.
# --ensure-main is also exercised here: master already exists (no-op path),
# proving --ensure-main no longer manufactures a bogus `main` when the real
# default branch is present under its own name.
"$WORKTREE_EXTEND" integrate --ensure-main --no-rebase "$REPO3" wtdefault-integrate minor /dev/null >/dev/null 2>&1 || true

expect "AC3: integrate merged onto master (working tree), not main" \
  "grep -q 'integrated via branch' "$REPO3/OTHER.md""
expect "AC3: --ensure-main did not touch/replace the stale main" \
  "[ \"\$(git -C "$REPO3" rev-parse main)\" = \"$OLD3\" ]"
expect "AC3: master (not main) now contains the integrated commit" \
  "git -C "$REPO3" merge-base --is-ancestor "$INTEGRATE_COMMIT" master"
expect "AC3: stale main never gained the integrated file" \
  "! git -C "$REPO3" show main:OTHER.md >/dev/null 2>&1"

# ── AC5: a full add -> commit -> land -> cleanup cycle in a repo with NO
#    pre-existing main leaves no stray local main branch behind ────────────
REPO5="$(mk_master_repo "$T" cycle)"
expect "AC5 precondition: no main branch exists yet" \
  "! git -C "$REPO5" show-ref --verify --quiet refs/heads/main"

WT5="$("$WORKTREE_EXTEND" add "$REPO5" wtdefault-cycle 2>/dev/null)"
printf 'cycle edit\n' >> "$WT5/README.md"
git -C "$WT5" "${GIT_ID[@]}" add -A
git -C "$WT5" "${GIT_ID[@]}" commit -q -m "wtdefault-cycle: edit"
"$WORKTREE_EXTEND" land "$REPO5" wtdefault-cycle >/dev/null 2>&1
cycle_rc=$?
expect "AC5: cycle's land exits 0" "[ $cycle_rc -eq 0 ]"
expect "AC5: cycle's edit landed on master" "grep -q 'cycle edit' "$REPO5/README.md""
expect "AC5: no stray local main branch was created by the cycle" \
  "! git -C "$REPO5" show-ref --verify --quiet refs/heads/main"
expect "AC5: no leftover worktree after land's cleanup" \
  "! git -C "$REPO5" worktree list --porcelain | grep -qF \"$BUILD_WT_ROOT\""

echo "---"
if [ "$fail" -eq 0 ]; then
  echo "worktree-extend-default-branch-selftest: ALL CHECKS PASS"
else
  echo "worktree-extend-default-branch-selftest: FAILURES ABOVE" >&2
fi
exit "$fail"
