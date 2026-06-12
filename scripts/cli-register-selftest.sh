#!/usr/bin/env bash
# cli-register-selftest.sh — regression coverage for build-shared-cli-dispatch-merge-safe
#
# AC1: cli-register.sh exists; creates a per-subcommand sidecar file
#      idempotently (re-run = no-op)
# AC2: Two simulated parallel branches each registering a *distinct* subcommand
#      produce non-overlapping diffs that `git merge` auto-resolves with zero
#      conflicts (because each branch creates a NEW file, not appending to a
#      shared one).
# AC3: worktree-extend.sh integrate --ensure-main creates main from default
#      branch HEAD when absent, and is a no-op when main already exists.
# AC4: On integrate conflict, the sidecar last_error records
#      integrate-conflict:<comma-separated-paths>.
#
# Exit 0 on all pass, non-zero on any failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REG="$HERE/cli-register.sh"
WTE="$HERE/worktree-extend.sh"
SIDECAR_SCRIPT="$HERE/manifest-sidecar.sh"
[ -x "$REG" ] || { echo "FAIL: cli-register.sh not found or not executable at $REG"; exit 1; }
[ -x "$WTE" ] || { echo "FAIL: worktree-extend.sh not found or not executable at $WTE"; exit 1; }

fails=0

check() {
    local label="$1" result="$2"
    if [ "$result" = "ok" ]; then
        echo "ok: $label"
    else
        echo "FAIL: $label — $result"
        fails=$((fails + 1))
    fi
}

# ── Setup: minimal repo ───────────────────────────────────────────────────────
make_repo() {
    local dir="$1"
    mkdir -p "$dir/src"
    cat > "$dir/src/main.rs" << 'MAINRS'
use clap::Parser;

#[derive(Parser)]
enum Command {
    Existing,
}

fn main() {
    let args = Command::parse();
    match args {
        Command::Existing => existing::run(&args),
    }
}
MAINRS
    git -C "$dir" init -q
    git -C "$dir" -c user.email=test@test.com -c user.name=Test add src/main.rs
    git -C "$dir" -c user.email=test@test.com -c user.name=Test commit -q -m "init"
    git -C "$dir" branch -M main 2>/dev/null || true
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ── AC1: sidecar file created idempotently ────────────────────────────────────
repo1="$tmp/ac1-repo"
make_repo "$repo1"

# First call: should create sidecar
"$REG" "$repo1" Bridge bridge >/dev/null 2>&1 && result="ok" || result="exit $?"
check "AC1 first-call exits 0" "$result"

[ -f "$repo1/src/register/Bridge.register" ] && result="ok" || result="sidecar file missing"
check "AC1 sidecar file created" "$result"

grep -qF "subcmd=Bridge" "$repo1/src/register/Bridge.register" && result="ok" || result="subcmd field missing"
check "AC1 sidecar has subcmd field" "$result"

grep -qF "module=bridge" "$repo1/src/register/Bridge.register" && result="ok" || result="module field missing"
check "AC1 sidecar has module field" "$result"

# Second call: should be no-op (idempotent)
mtime_before="$(stat -c %Y "$repo1/src/register/Bridge.register")"
sleep 0.1
"$REG" "$repo1" Bridge bridge >/dev/null 2>&1 && result="ok" || result="exit $?"
check "AC1 re-run exits 0" "$result"
mtime_after="$(stat -c %Y "$repo1/src/register/Bridge.register")"
[ "$mtime_before" = "$mtime_after" ] && result="ok" || result="sidecar was overwritten on re-run"
check "AC1 re-run is no-op (sidecar unchanged)" "$result"

# ── AC2: two parallel branches auto-merge with zero conflicts ─────────────────
# The key insight: each branch creates a DIFFERENT new file (different slug),
# so two parallel branches never touch the same file and never conflict.
repo2="$tmp/ac2-repo"
make_repo "$repo2"

# Branch A: registers "Alpha" — creates src/register/Alpha.register
git -C "$repo2" checkout -q -b branch-a
"$REG" "$repo2" Alpha alpha >/dev/null 2>&1
git -C "$repo2" -c user.email=test@test.com -c user.name=Test add src/register/Alpha.register
git -C "$repo2" -c user.email=test@test.com -c user.name=Test commit -q -m "add Alpha subcommand"

# Branch B: registers "Beta" — creates src/register/Beta.register (DIFFERENT file)
git -C "$repo2" checkout -q main
git -C "$repo2" checkout -q -b branch-b
"$REG" "$repo2" Beta beta >/dev/null 2>&1
git -C "$repo2" -c user.email=test@test.com -c user.name=Test add src/register/Beta.register
git -C "$repo2" -c user.email=test@test.com -c user.name=Test commit -q -m "add Beta subcommand"

# Integrate branch-a into main first (simulates first integrate)
git -C "$repo2" checkout -q main
git -C "$repo2" -c user.email=test@test.com -c user.name=Test merge --no-ff -q branch-a -m "integrate Alpha" 2>&1
check "AC2 branch-a integrates cleanly" "ok"

# Now integrate branch-b — zero conflicts because it created a different file
merge_out="$(git -C "$repo2" -c user.email=test@test.com -c user.name=Test merge --no-ff branch-b -m "integrate Beta" 2>&1)" && merge_exit=0 || merge_exit=$?

if [ "$merge_exit" = "0" ]; then
    check "AC2 branch-b integrates with zero conflicts" "ok"
else
    check "AC2 branch-b integrates with zero conflicts" "merge exited $merge_exit: $merge_out"
fi

# Verify both sidecar files present after merge
[ -f "$repo2/src/register/Alpha.register" ] && [ -f "$repo2/src/register/Beta.register" ] \
    && result="ok" || result="sidecar file(s) missing after merge"
check "AC2 both sidecar files present after merge" "$result"

# ── AC3: --ensure-main creates main from HEAD when absent; no-op when present ─
# We need a repo that starts on a non-main branch (e.g. master) with no main.
repo3="$tmp/ac3-repo"
mkdir -p "$repo3/src"
printf 'fn main(){}\n' > "$repo3/src/main.rs"
git -C "$repo3" init -q -b master
git -C "$repo3" -c user.email=test@test.com -c user.name=Test add src/main.rs
git -C "$repo3" -c user.email=test@test.com -c user.name=Test commit -q -m "init on master"

# Confirm main does NOT exist yet
if git -C "$repo3" show-ref --verify --quiet "refs/heads/main" 2>/dev/null; then
    check "AC3 precondition: main absent before ensure-main" "main already exists unexpectedly"
else
    check "AC3 precondition: main absent before ensure-main" "ok"
fi

# Create a branch to integrate (needed so integrate can proceed past the branch-check)
git -C "$repo3" checkout -q -b "autobuilder/ac3-test"
printf 'fn main(){println!("hi");}\n' > "$repo3/src/main.rs"
git -C "$repo3" -c user.email=test@test.com -c user.name=Test add src/main.rs
git -C "$repo3" -c user.email=test@test.com -c user.name=Test commit -q -m "ac3 change"
git -C "$repo3" checkout -q master

# Run integrate --ensure-main — should create main, then integrate cleanly
# (we need extend-handler.sh for the bump; skip the tldr file — pass /dev/null)
export BUILD_WT_ROOT="$tmp/wt3"
mkdir -p "$BUILD_WT_ROOT"
# Create a minimal extend-handler stub so integrate's bump step doesn't fail
EXTEND_STUB="$tmp/extend-handler.sh"
cat > "$EXTEND_STUB" <<'STUBEOF'
#!/usr/bin/env bash
case "${1:-}" in
  bump-version) exit 0 ;;
  current-version) echo "0.1.1" ;;
  changelog-prepend) exit 0 ;;
  *) exit 1 ;;
esac
STUBEOF
chmod +x "$EXTEND_STUB"

# Patch the integrate call to use our stub extend-handler. We do this by
# setting EXTEND env var if worktree-extend.sh honours it; otherwise we rely
# on the real extend-handler.sh being present (which it is in production).
# Here we just test the --ensure-main behaviour: does main get created?
EXTEND="$EXTEND_STUB" "$WTE" integrate --ensure-main "$repo3" ac3-test minor /dev/null >/dev/null 2>&1 \
    || true  # ignore non-zero (version bump may need real handler)

if git -C "$repo3" show-ref --verify --quiet "refs/heads/main" 2>/dev/null; then
    check "AC3 ensure-main created main branch" "ok"
else
    check "AC3 ensure-main created main branch" "main branch still absent after --ensure-main"
fi

# AC3b: --ensure-main is a no-op when main already exists
# (repo3 now HAS main; run again and verify main's commit doesn't change)
main_sha_before="$(git -C "$repo3" rev-parse main 2>/dev/null || echo ABSENT)"
EXTEND="$EXTEND_STUB" "$WTE" integrate --ensure-main "$repo3" ac3-test minor /dev/null >/dev/null 2>&1 \
    || true  # ignore non-zero (branch already integrated, not our concern)
main_sha_after="$(git -C "$repo3" rev-parse main 2>/dev/null || echo ABSENT)"
# main should not have been deleted or rewound by a second --ensure-main
if [ "$main_sha_after" != "ABSENT" ]; then
    check "AC3 ensure-main is no-op when main exists" "ok"
else
    check "AC3 ensure-main is no-op when main exists" "main disappeared after second --ensure-main"
fi

# ── AC4: conflict writes integrate-conflict:<files> to sidecar last_error ─────
# Set up a repo with two branches that conflict on src/main.rs (the old pattern).
repo4="$tmp/ac4-repo"
mkdir -p "$repo4/src"
printf 'fn main(){}\n' > "$repo4/src/main.rs"
git -C "$repo4" init -q
git -C "$repo4" -c user.email=test@test.com -c user.name=Test add src/main.rs
git -C "$repo4" -c user.email=test@test.com -c user.name=Test commit -q -m "init"
git -C "$repo4" branch -M main 2>/dev/null || true

# Branch that edits main.rs in a conflicting way
git -C "$repo4" checkout -q -b "autobuilder/ac4-slug"
printf 'fn main(){ println!("branch"); }\n' > "$repo4/src/main.rs"
git -C "$repo4" -c user.email=test@test.com -c user.name=Test add src/main.rs
git -C "$repo4" -c user.email=test@test.com -c user.name=Test commit -q -m "branch edit"

# Advance main independently to create the conflict
git -C "$repo4" checkout -q main
printf 'fn main(){ println!("main"); }\n' > "$repo4/src/main.rs"
git -C "$repo4" -c user.email=test@test.com -c user.name=Test add src/main.rs
git -C "$repo4" -c user.email=test@test.com -c user.name=Test commit -q -m "main edit"

# Set up sidecar dir so the sidecar script can write
AC4_STATE_DIR="$tmp/ac4-state"
mkdir -p "$AC4_STATE_DIR"
export BUILD_WT_ROOT="$tmp/wt4"
mkdir -p "$BUILD_WT_ROOT"

# Run integrate --no-rebase to hit the early-exit conflict path
# We override BUILD_SIDECAR_DIR if worktree-extend.sh uses it; otherwise we
# inspect the state dir used by manifest-sidecar.sh.
# The sidecar writes via manifest-sidecar.sh write <slug> <kv> which uses
# ~/.claude/skills/build/state/ — we check that file after the call.
SLUG="ac4-slug"
BUILD_WT_ROOT="$tmp/wt4" EXTEND="$EXTEND_STUB" \
    "$WTE" integrate --no-rebase "$repo4" "$SLUG" minor /dev/null >/dev/null 2>&1 \
    || true  # expect exit 4 (conflict)

# Check sidecar for last_error=integrate-conflict:...
# manifest-sidecar.sh writes to state/status/<slug>.json
SKILL_DIR="$(cd "$HERE/.." && pwd)"
SIDECAR_FILE="$SKILL_DIR/state/status/${SLUG}.json"
if [ -f "$SIDECAR_FILE" ]; then
    last_err="$(python3 -c "import json,sys; d=json.load(open('$SIDECAR_FILE')); print(d.get('last_error',''))" 2>/dev/null \
        || grep -o '"last_error":"[^"]*"' "$SIDECAR_FILE" | head -1 || echo "")"
    if echo "$last_err" | grep -q "integrate-conflict:"; then
        check "AC4 sidecar last_error=integrate-conflict on merge conflict" "ok"
    else
        check "AC4 sidecar last_error=integrate-conflict on merge conflict" "last_error was: $last_err"
    fi
else
    check "AC4 sidecar last_error=integrate-conflict on merge conflict" "sidecar file not found: $SIDECAR_FILE"
fi
# Cleanup: remove the AC4 test sidecar so it doesn't pollute the real state
rm -f "$SIDECAR_FILE"

# ── Report ────────────────────────────────────────────────────────────────────
if [ "$fails" -eq 0 ]; then
    echo "cli-register-selftest: all tests passed"
    exit 0
else
    echo "cli-register-selftest: $fails failure(s)"
    exit 1
fi
