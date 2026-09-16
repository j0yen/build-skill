#!/usr/bin/env bash
# tests/xrepo_ac3_pass_after_routing.sh — PRD-build-cross-repo-commit-gate
# requirement 2 (P0) / AC3: the SAME fixture as xrepo_ac2, but the commit
# ALSO extends proof-lanes.toml's lane to cover the new file's path in the
# same commit — the land now journals `cross-repo-gate  pass`, and the
# target's default branch actually advances (the merge landed).
#
# Real git + cargo + autobuilder (no mocks); slow (~1-2 minutes).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORKTREE_EXTEND="$HERE/../scripts/worktree-extend.sh"
[ -x "$WORKTREE_EXTEND" ] || { echo "selftest: $WORKTREE_EXTEND not executable" >&2; exit 2; }
for bin in git jq flock cargo autobuilder python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done
# shellcheck source=fixtures/xrepo-common.sh
source "$HERE/fixtures/xrepo-common.sh"

XREPO_TMPDIR="${TMPDIR:-/tmp}"
if [ -d /mnt/data ]; then XREPO_TMPDIR="/mnt/data/jsy/tmp"; fi
mkdir -p "$XREPO_TMPDIR"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "$XREPO_TMPDIR/xrepo-ac3-selftest.XXXXXX")"
export BUILD_WT_ROOT="$T/build-worktrees"
trap '[ -n "${XREPO_AC3_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$(xrepo_mk_target_repo "$T")"
REPO_RP="$(cd "$REPO" && pwd -P)"

MANIFEST="$T/manifest.json"
xrepo_mkfixture_manifest "$MANIFEST" "$REPO_RP" "some-owner-prd"

WRITER_HOME="$T/writer-home"
mkdir -p "$WRITER_HOME"

SLUG="xrepo-ac3-writer-$$"
WT="$("$WORKTREE_EXTEND" add "$REPO" "$SLUG" 2>/dev/null)"
expect "setup: worktree created" "[ -d \"$WT\" ]"

mkdir -p "$WT/config"
printf 'unrouted = true\n' > "$WT/config/unrouted.toml"
# Extend the SAME lane, in the SAME commit, to cover config/**/*.toml —
# requirement 4's "adding the lane in the same commit makes it pass".
python3 - "$WT/agent/proof-lanes.toml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'globs = ["src/**/*.rs", "agent/**"]',
    'globs = ["src/**/*.rs", "agent/**", "config/**/*.toml"]',
)
open(p, "w").write(s)
PY
xrepo_gitid -C "$WT" add -A
xrepo_gitid -C "$WT" commit -q -m "add routed config file"

JOURNAL="$T/journal.md"
BEFORE_MAIN="$(git -C "$REPO" rev-parse main)"

echo "=== AC3: land passes once the new path is routed ==="
out="$T/land.out"
PATH="$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH" \
  REVIEWER_PROMPT=/nonexistent/xrepo-ac3-reviewer-prompt.md \
  BUILD_MANIFEST="$MANIFEST" BUILD_STATE_DIR="$T/state" BUILD_JOURNAL_ROOT="$T/journalroot" \
  WORKTREE_EXTEND_JOURNAL="$JOURNAL" \
  timeout -k 5 180 "$WORKTREE_EXTEND" land "$REPO" "$SLUG" --writer-build-into "$WRITER_HOME" >"$out" 2>&1
rc=$?
expect "AC3: land exits 0" "[ $rc -eq 0 ]"

journal_line="$(grep "cross-repo-gate  pass" "$JOURNAL" 2>/dev/null | tail -1)"
expect "AC3: a cross-repo-gate pass journal line was written" "[ -n \"$journal_line\" ]"
expect "AC3: journal line names writer=$SLUG" "printf '%s' \"$journal_line\" | grep -q \"writer=$SLUG \""
expect "AC3: journal line names target=target-repo" "printf '%s' \"$journal_line\" | grep -q 'target=target-repo'"

expect "AC3: target repo's default branch advanced (the merge landed)" \
  "[ \"\$(git -C \"$REPO\" rev-parse main)\" != \"$BEFORE_MAIN\" ]"
expect "AC3: the config file is present on main after the merge" \
  "git -C \"$REPO\" show main:config/unrouted.toml >/dev/null 2>&1"

echo "  journal: $journal_line"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "xrepo_ac3: ALL PASS"
else
  echo "xrepo_ac3: assertion(s) FAILED"
fi
exit "$fail"
