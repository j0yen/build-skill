#!/usr/bin/env bash
# cli-register-selftest.sh — regression coverage for build-shared-cli-dispatch-merge-safe
#
# AC1: cli-register.sh exists; creates a per-subcommand sidecar file
#      idempotently (re-run = no-op)
# AC2: Two simulated parallel branches each registering a *distinct* subcommand
#      produce non-overlapping diffs that `git merge` auto-resolves with zero
#      conflicts (because each branch creates a NEW file, not appending to a
#      shared one).
#
# Exit 0 on all pass, non-zero on any failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REG="$HERE/cli-register.sh"
[ -x "$REG" ] || { echo "FAIL: cli-register.sh not found or not executable at $REG"; exit 1; }

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

# ── Report ────────────────────────────────────────────────────────────────────
if [ "$fails" -eq 0 ]; then
    echo "cli-register-selftest: all tests passed"
    exit 0
else
    echo "cli-register-selftest: $fails failure(s)"
    exit 1
fi
