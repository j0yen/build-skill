#!/usr/bin/env bash
# extend-gate-scope-selftest.sh — PRD-build-gate-before-land requirement 1
# (P0) / AC1: a branch-scoped gate (`--scope branch --slug <slug>`) runs
# the full producer sequence inside a worktree, under a per-branch lock
# instead of the shared per-crate `autobuilder-integrate.lock`, writes
# receipts and last-verdict.json under the worktree's own (off-root)
# target dir, and journals `scope=branch slug=<slug> ... base=<main sha
# at gate start>` — not the rollback-plan tag `--scope main` still uses.
#
# Builds ONE disposable rust-extend fixture repo under $TMPDIR (never
# mcphost, never any production repo), adds a real `git worktree` of it
# with an off-root `.cargo/config.toml` target-dir (mirroring
# PRD-build-worktree-targets-off-root's convention), advances the MAIN
# checkout's HEAD by one commit after the worktree is created (so
# base=<main sha> is observably the advanced main HEAD, not the
# worktree's own HEAD or the tag-based rollback base), then runs
# extend-gate.sh once against the worktree with --scope branch.
#
#   AC1a — receipts + last-verdict.json land under the worktree's
#          resolved (off-root) target dir.
#   AC1b — no `autobuilder-integrate.lock` file is ever created; a
#          `autobuilder-gate-<slug>.lock` is.
#   AC1c — the journal line carries `scope=branch slug=<slug>` and
#          `base=<main sha>` (the ADVANCED main HEAD, not the worktree's
#          own HEAD).
#
# Regression: `--scope main` (the default, omitted here) is covered by
# extend-gate-concurrent-selftest.sh, unmodified by this PRD.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXTEND_GATE="$HERE/extend-gate.sh"
[ -x "$EXTEND_GATE" ] || { echo "selftest: $EXTEND_GATE not executable" >&2; exit 2; }
for bin in git jq flock fuser cargo autobuilder; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/extend-gate-scope-selftest.XXXXXX")"
trap '[ -n "${EXTEND_GATE_SCOPE_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
WT="$T/worktree"
OFFROOT_TARGET="$T/offroot-target"
mkdir -p "$REPO/src" "$REPO/agent" "$REPO/tests" "$REPO/scripts"

cat > "$REPO/Cargo.toml" <<'EOF'
[package]
name = "gatescope-fixture"
version = "0.1.0"
edition = "2021"
license = "MIT"

[dependencies]
EOF

cat > "$REPO/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF

cat > "$REPO/tests/gatescope_ac1.rs" <<'EOF'
use gatescope_fixture::add;

#[test]
fn ac1_add_returns_sum() {
    assert_eq!(add(2, 2), 4);
}
EOF

cat > "$REPO/agent/intent-card.json" <<'EOF'
{
  "schema": "autobuilder.intent_card.v1",
  "prd_source": "inline",
  "intent_slug": "gatescope-fixture",
  "root_motivation": "Disposable fixture crate for extend-gate-scope-selftest.sh (PRD-build-gate-before-land) — not a real product, never mcphost.",
  "user_persona": "test harness only",
  "unfakeable_metric": {"name": "acceptance_tests_passing_count", "lower_is_better": false, "harness_command": "scripts/run-metrics.sh", "target": 1},
  "acceptance_criteria": [
    {"id": "AC1", "level": "MUST", "description": "Given add(2,2), When called, Then it returns 4.", "test": "tests/gatescope_ac1.rs"}
  ],
  "scope": ["src/lib.rs"],
  "non_goals": ["none — fixture only"],
  "hard_constraints": {"rust_edition": "2021", "target_kind": "lib", "deny_unsafe": true},
  "five_whys_trace": [
    {"why": 1, "q": "why does this crate exist", "a": "to give extend-gate-scope-selftest.sh a disposable rust-extend fixture"}
  ],
  "ambiguities_resolved": [],
  "created_at": "2026-09-14T00:00:00Z"
}
EOF

cat > "$REPO/agent/proof-lanes.toml" <<'EOF'
[[lane]]
id = "rust-source"
description = "fixture lane"
globs = ["src/**/*.rs"]
required_commands = ["cargo check"]
EOF

cat > "$REPO/scripts/run-metrics.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
head_sha="$(git rev-parse HEAD)"
captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p target/autobuilder
jq -n --arg head "$head_sha" --arg ts "$captured_at" '{
  schema: "autobuilder.metrics.v1",
  head_sha: $head,
  scalars: {acceptance_tests_passing_count: 1},
  ac_passing_count: 1,
  ac_total_count: 1,
  audit: {blocking_count: 0, advisory_count: 0},
  clippy_warning_count: 0,
  captured_at: $ts
}' > target/autobuilder/metrics.json
EOF
chmod +x "$REPO/scripts/run-metrics.sh"

cat > "$REPO/.gitignore" <<'EOF'
/target
/.cargo
EOF

( cd "$REPO" && cargo generate-lockfile >/dev/null 2>&1 ) || true

git -C "$REPO" init -q
git -C "$REPO" -c user.name="extend-gate-scope-selftest" -c user.email="selftest@example.com" add -A
git -C "$REPO" -c user.name="extend-gate-scope-selftest" -c user.email="selftest@example.com" commit -q -m "initial"
git -C "$REPO" tag v0.1.0
INITIAL_SHA="$(git -C "$REPO" rev-parse HEAD)"

# --- real worktree via the production `worktree-extend.sh add` path
#     (not hand-built) — so this selftest exercises the EXACT off-root
#     target-dir + target/ symlink mechanism a real branch agent gets,
#     mirroring PRD-build-worktree-targets-off-root's convention. -------
WORKTREE_EXTEND="$HERE/worktree-extend.sh"
[ -x "$WORKTREE_EXTEND" ] || { echo "selftest: $WORKTREE_EXTEND not executable" >&2; exit 2; }
SLUG="gatescope-selftest-$$"
mkdir -p "$OFFROOT_TARGET"
WT="$(BUILD_TARGET_ROOT="$OFFROOT_TARGET" "$WORKTREE_EXTEND" add "$REPO" "$SLUG")"
expect "setup: worktree-extend.sh add printed a worktree path that exists" "[ -d \"$WT\" ]"
EXPECTED_TDIR="$OFFROOT_TARGET/$(basename "$REPO")-$SLUG"
WT_HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"

# --- advance MAIN's HEAD after the worktree exists, so base=<main sha>
#     is observably different from the worktree's own HEAD/tag base -----
echo "advance" > "$REPO/README-advance.md"
git -C "$REPO" -c user.name="extend-gate-scope-selftest" -c user.email="selftest@example.com" add README-advance.md
git -C "$REPO" -c user.name="extend-gate-scope-selftest" -c user.email="selftest@example.com" commit -q -m "advance main after worktree creation"
MAIN_SHA_AT_GATE_START="$(git -C "$REPO" rev-parse HEAD)"
expect "setup: main HEAD advanced past the worktree's own HEAD" "[ \"$MAIN_SHA_AT_GATE_START\" != \"$WT_HEAD_SHA\" ]"

JOURNAL="$T/journal.md"

COMMON_ENV=(
  "PATH=$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH"
  "REVIEWER_PROMPT=/nonexistent/extend-gate-scope-selftest-reviewer-prompt.md"
  "EXTEND_GATE_JOURNAL=$JOURNAL"
)

echo "=== AC1: extend-gate.sh --scope branch --slug $SLUG against a worktree ==="
out="$T/out.log"
env "${COMMON_ENV[@]}" timeout -k 5 90 "$EXTEND_GATE" "$WT" --head "$WT_HEAD_SHA" --scope branch --slug "$SLUG" --force >"$out" 2>&1
rc=$?
expect "AC1: run completes (pass=0 or block=1, not a crash/timeout)" "[ $rc -eq 0 ] || [ $rc -eq 1 ]"
cat "$out"

git_common_dir="$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)"
BRANCH_LOCK="$git_common_dir/autobuilder-gate-$SLUG.lock"
INTEGRATE_LOCK="$git_common_dir/autobuilder-integrate.lock"

expect "AC1b: per-branch lock file was created (autobuilder-gate-$SLUG.lock)" "[ -f \"$BRANCH_LOCK\" ]"
expect "AC1b: no autobuilder-integrate.lock was ever acquired" "[ ! -f \"$INTEGRATE_LOCK\" ]"

# Precompute derived values before building `cond` strings — a command
# substitution with escaped quotes NESTED inside an already-double-quoted
# `expect` argument does not re-quote for the inner command (the backslash
# only affects the outer parse), so `$(readlink \"$WT/target\")` silently
# readlinks a literal-quote-mangled path and returns empty. Every other
# `expect` call in this file's sibling selftests avoids this the same way:
# compute first, embed only the resulting VALUE.
wt_target_link="$(readlink "$WT/target" 2>/dev/null || true)"
receipts_listing="$(ls -A "$EXPECTED_TDIR/autobuilder/receipts" 2>/dev/null || true)"
expect "AC1a: worktree's target/ is a symlink to the off-root target dir" \
  "[ -L \"$WT/target\" ] && [ \"$wt_target_link\" = \"$EXPECTED_TDIR\" ]"
expect "AC1a: receipts exist under the worktree's resolved (off-root) target dir" \
  "[ -d \"$EXPECTED_TDIR/autobuilder/receipts\" ] && [ -n \"$receipts_listing\" ]"
expect "AC1a: last-verdict.json exists under the worktree's resolved (off-root) target dir" \
  "[ -f \"$EXPECTED_TDIR/autobuilder/last-verdict.json\" ]"


# extend-gate.sh's own "reviewer skipped" line (written earlier than the
# final verdict, when the run already has blocking notes) shares the
# `  gate  ` marker — grep it out so this picks the actual verdict line,
# not whichever "  gate  " line comes first. (Before PRD-build-gate-
# before-land requirement 7's drive-by fix, "reviewer-skipped" bypassed
# EXTEND_GATE_JOURNAL entirely and never appeared in $JOURNAL at all,
# which is why this selector never needed to care before.)
journal_line="$(grep "  gate  " "$JOURNAL" 2>/dev/null | grep -v reviewer-skipped | head -1 || true)"
expect "AC1c: a gate journal line was written" "[ -n \"$journal_line\" ]"
expect "AC1c: journal line carries scope=branch slug=$SLUG" "printf '%s' \"$journal_line\" | grep -q 'scope=branch slug=$SLUG '"
expect "AC1c: journal line's base= names the ADVANCED main HEAD" "printf '%s' \"$journal_line\" | grep -q \"base=$MAIN_SHA_AT_GATE_START \""
expect "AC1c: journal line's base= is NOT the worktree's own HEAD" "! printf '%s' \"$journal_line\" | grep -q \"base=$WT_HEAD_SHA \""
echo "  journal: $journal_line"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "extend-gate-scope-selftest: ALL PASS"
  exit 0
else
  echo "extend-gate-scope-selftest: assertion(s) FAILED"
  exit 1
fi
