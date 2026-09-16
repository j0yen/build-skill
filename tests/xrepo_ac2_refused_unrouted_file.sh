#!/usr/bin/env bash
# tests/xrepo_ac2_refused_unrouted_file.sh — PRD-build-cross-repo-commit-
# gate requirement 2 (P0) / AC2: a fixture shell PRD committing an
# unrouted file into a fixture gated repo has its land step refused, the
# journal carries `cross-repo-gate  refused  (writer=… target=…
# blocking=vti-plan,…)`, and the target's default branch is unchanged.
#
# Real git + cargo + autobuilder (no mocks) — this is the actual
# extend-gate.sh --scope branch producer sequence a real cross-repo land
# would run, same fixture-crate recipe as extend-gate-scope-selftest.sh
# (PRD-build-gate-before-land), extended with a proof-lanes.toml split so
# ONE unrouted file is the single thing separating this test from
# xrepo_ac3 (routed, pass). Slow (~1-2 minutes: a real cargo build/test
# cycle) — this is requirement 4's fixture, not a unit test.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORKTREE_EXTEND="$HERE/../scripts/worktree-extend.sh"
[ -x "$WORKTREE_EXTEND" ] || { echo "selftest: $WORKTREE_EXTEND not executable" >&2; exit 2; }
for bin in git jq flock cargo autobuilder python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done
# shellcheck source=fixtures/xrepo-common.sh
source "$HERE/fixtures/xrepo-common.sh"

# A real fixture build needs real (non-tmpfs) disk headroom — extend-
# gate.sh's own risk-gate refuses under a 5GB-free floor, and /tmp is
# commonly a small tmpfs on this fleet (self_selftest_tmpfs_disk_guard).
XREPO_TMPDIR="${TMPDIR:-/tmp}"
if [ -d /mnt/data ]; then XREPO_TMPDIR="/mnt/data/jsy/tmp"; fi
mkdir -p "$XREPO_TMPDIR"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "$XREPO_TMPDIR/xrepo-ac2-selftest.XXXXXX")"
export BUILD_WT_ROOT="$T/build-worktrees"
trap '[ -n "${XREPO_AC2_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$(xrepo_mk_target_repo "$T")"
REPO_RP="$(cd "$REPO" && pwd -P)"

MANIFEST="$T/manifest.json"
xrepo_mkfixture_manifest "$MANIFEST" "$REPO_RP" "some-owner-prd"

WRITER_HOME="$T/writer-home"
mkdir -p "$WRITER_HOME"

SLUG="xrepo-ac2-writer-$$"
WT="$("$WORKTREE_EXTEND" add "$REPO" "$SLUG" 2>/dev/null)"
expect "setup: worktree created" "[ -d \"$WT\" ]"

mkdir -p "$WT/config"
printf 'unrouted = true\n' > "$WT/config/unrouted.toml"
xrepo_gitid -C "$WT" add -A
xrepo_gitid -C "$WT" commit -q -m "add unrouted file"

JOURNAL="$T/journal.md"
BEFORE_MAIN="$(git -C "$REPO" rev-parse main)"

echo "=== AC2: land refuses on an unrouted cross-repo write ==="
out="$T/land.out"
PATH="$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH" \
  REVIEWER_PROMPT=/nonexistent/xrepo-ac2-reviewer-prompt.md \
  BUILD_MANIFEST="$MANIFEST" BUILD_STATE_DIR="$T/state" BUILD_JOURNAL_ROOT="$T/journalroot" \
  WORKTREE_EXTEND_JOURNAL="$JOURNAL" \
  timeout -k 5 180 "$WORKTREE_EXTEND" land "$REPO" "$SLUG" --writer-build-into "$WRITER_HOME" >"$out" 2>&1
rc=$?
expect "AC2: land exits 8 (cross-repo-gate refused)" "[ $rc -eq 8 ]"

journal_line="$(grep "cross-repo-gate  refused" "$JOURNAL" 2>/dev/null | tail -1)"
expect "AC2: a cross-repo-gate refused journal line was written" "[ -n \"$journal_line\" ]"
expect "AC2: journal line names writer=$SLUG" "printf '%s' \"$journal_line\" | grep -q \"writer=$SLUG \""
expect "AC2: journal line names target=target-repo" "printf '%s' \"$journal_line\" | grep -q 'target=target-repo '"
expect "AC2: journal line's blocking= names vti-plan" "printf '%s' \"$journal_line\" | grep -q 'blocking=.*vti-plan'"

expect "AC2: target repo's default branch is unchanged" "[ \"\$(git -C \"$REPO\" rev-parse main)\" = \"$BEFORE_MAIN\" ]"
expect "AC2: the writer's branch still exists (not landed)" \
  "git -C \"$REPO\" show-ref --verify --quiet refs/heads/autobuilder/$SLUG"

echo "  journal: $journal_line"
cat "$out" | tail -15

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "xrepo_ac2: ALL PASS"
else
  echo "xrepo_ac2: assertion(s) FAILED"
fi
exit "$fail"
