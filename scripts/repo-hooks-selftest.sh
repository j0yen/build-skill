#!/usr/bin/env bash
# repo-hooks-selftest.sh — fixture coverage for scripts/repo-hooks/{pre-commit,pre-push}: with core.hooksPath at the shared dir, a repo-local .git/hooks hook still runs (the `live-clone-guard-chain` marker).
#
# Cases: refusing local pre-commit refuses `git commit`; no local hook -> commit passes; a linked worktree chains to the main repo's hook;
# the hook files are executable and carry the marker; pre-push chains (local refusal refuses the push, ref lines reach the local hook on stdin, no local hook -> push passes).
#
# Usage: repo-hooks-selftest.sh [--selftest]      Exit 0 all green | 1 a case failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$HERE/repo-hooks"
t="$(mktemp -d "${TMPDIR:-/tmp}/repo-hooks-selftest.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$t"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export BUILD_JOURNAL_ROOT="$t/journal"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

[ -x "$HOOKS/pre-commit" ] && ok "pre-commit is executable" || bad "pre-commit not executable"
[ -x "$HOOKS/pre-push" ] && ok "pre-push is executable" || bad "pre-push not executable"
grep -q '^# live-clone-guard-chain$' "$HOOKS/pre-commit" && ok "pre-commit carries the live-clone-guard-chain marker" || bad "marker missing"

repo="$t/repo"
git init -q "$repo" && git -C "$repo" commit -q --allow-empty -m init
git -C "$repo" config core.hooksPath "$HOOKS"

# no local hook: commit passes
git -C "$repo" commit -q --allow-empty -m a 2>/dev/null && ok "no local pre-commit: commit passes" || bad "commit refused without a local hook"

# refusing local hook (exactly what live-clone-guard.sh writes, in spirit)
printf '#!/bin/sh\necho "local-pre-commit-ran $*" >&2\nexit 1\n' > "$repo/.git/hooks/pre-commit"; chmod 755 "$repo/.git/hooks/pre-commit"
out=$(git -C "$repo" commit --allow-empty -m b 2>&1); rc=$?
{ [ $rc -ne 0 ] && grep -q local-pre-commit-ran <<<"$out"; } && ok "refusing local pre-commit refuses git commit through the chain" || bad "chain commit rc=$rc out=$out"

# non-executable local hook is ignored
chmod 644 "$repo/.git/hooks/pre-commit"
git -C "$repo" commit -q --allow-empty -m c 2>/dev/null && ok "non-executable local hook is ignored (as git does)" || bad "non-exec hook blocked commit"
chmod 755 "$repo/.git/hooks/pre-commit"

# linked worktree chains to the main repo's hook
wt="$t/wt"
git -C "$repo" worktree add -q "$wt" -b feat 2>/dev/null
out=$(git -C "$wt" commit --allow-empty -m d 2>&1); rc=$?
{ [ $rc -ne 0 ] && grep -q local-pre-commit-ran <<<"$out"; } && ok "a linked worktree chains to the main repo's pre-commit" || bad "worktree chain rc=$rc out=$out"
rm -f "$repo/.git/hooks/pre-commit"
git -C "$wt" commit -q --allow-empty -m e 2>/dev/null && ok "worktree commit passes without a local hook" || bad "worktree commit refused without a local hook"

# a hook run from a subdirectory still resolves the relative common dir
mkdir -p "$repo/sub"; printf '#!/bin/sh\nexit 1\n' > "$repo/.git/hooks/pre-commit"; chmod 755 "$repo/.git/hooks/pre-commit"
( cd "$repo/sub" && git commit -q --allow-empty -m f 2>/dev/null ) && bad "commit from a subdir not refused" || ok "commit from a subdirectory is refused through the chain"
rm -f "$repo/.git/hooks/pre-commit"

# pre-push chain: non-main branch so the main-push-gate itself is not involved
git init -q --bare "$t/origin.git"; git -C "$repo" remote add origin "$t/origin.git"
git -C "$repo" push -q origin HEAD:refs/heads/topic 2>/dev/null && ok "no local pre-push: push of a non-main branch passes" || bad "push refused without a local hook"
printf '#!/bin/sh\ncat > "%s/pp-stdin"\necho "local-pre-push-ran $1" >&2\nexit 1\n' "$t" > "$repo/.git/hooks/pre-push"; chmod 755 "$repo/.git/hooks/pre-push"
out=$(git -C "$repo" push origin HEAD:refs/heads/topic2 2>&1); rc=$?
{ [ $rc -ne 0 ] && grep -q local-pre-push-ran <<<"$out"; } && ok "refusing local pre-push refuses the push through the chain" || bad "pre-push chain rc=$rc out=$out"
grep -q 'refs/heads/topic2' "$t/pp-stdin" 2>/dev/null && ok "ref lines reach the local pre-push on stdin" || bad "local pre-push got no stdin"
[ -z "$(git -C "$t/origin.git" rev-parse --verify -q refs/heads/topic2)" ] && ok "refused push left the remote unchanged" || bad "remote advanced despite refusal"

echo "selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
