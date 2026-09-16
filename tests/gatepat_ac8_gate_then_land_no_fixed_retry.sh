#!/usr/bin/env bash
# gatepat_ac8_gate_then_land_no_fixed_retry.sh —
# PRD-build-gate-patience-from-queue-depth AC8 (requirement 2/6): given
# `gate-then-land.sh` and a branch gate that reports contention (exit 4 —
# "patience already exhausted, inside extend-gate.sh's own single flock
# wait"), when it runs, then it exits 12 (`contended`), journals exactly
# one `contended` line with no `block`/`gate-red`/`verdict=block` wording
# anywhere, and — the "no fixed 90s retry boundary" half of AC8 — calls
# the underlying gate exactly ONCE: a caller that retried on a contended
# exit would just re-pay the same already-exhausted wait, which is
# precisely the "3 attempts of 90s" shape this PRD removes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatepat-common.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/gatepat_ac8.XXXXXX")"
export BUILD_WT_ROOT="$T/build-worktrees"
export STATE_DIR="$T/state"
GIT_ID=(-c user.email=t@t.local -c user.name=gatepat-ac8)
trap 'rm -rf "$T"' EXIT

# Fake extend-gate.sh: always reports lock-contended (exit 4), records how
# many times it was invoked in "gate" mode (never --print-verdict-path) so
# the test can assert "exactly once, no retry".
CALL_LOG="$T/call-count.log"
: > "$CALL_LOG"
cat > "$T/fake-extend-gate.sh" <<FAKE
#!/usr/bin/env bash
set -uo pipefail
mode="gate"
for a in "\$@"; do
  [ "\$a" = "--print-verdict-path" ] && mode="path"
done
if [ "\$mode" = path ]; then
  echo "$T/verdict.json"
  exit 0
fi
echo x >> "$CALL_LOG"
exit 4
FAKE
chmod +x "$T/fake-extend-gate.sh"

REPO="$T/mcphost"
mkdir -p "$REPO/src"
git -C "$REPO" init -q -b main
printf '/target\n/.cargo\n' > "$REPO/.gitignore"
printf 'pub fn f() {}\n' > "$REPO/src/lib.rs"
cat > "$REPO/Cargo.toml" <<EOF
[package]
name = "mcphost"
version = "0.1.0"
EOF
git -C "$REPO" "${GIT_ID[@]}" add -A
git -C "$REPO" "${GIT_ID[@]}" commit -q -m init
WT="$("$GATEPAT_SCRIPTS/worktree-extend.sh" add "$REPO" "ac8-slug" 2>/dev/null)"
printf 'pub fn g() {}\n' >> "$WT/src/lib.rs"
git -C "$WT" "${GIT_ID[@]}" add -A
git -C "$WT" "${GIT_ID[@]}" commit -q -m "branch work"

JOURNAL="$T/journal.md"
out="$T/out.log"
env GATE_THEN_LAND_EXTEND_GATE="$T/fake-extend-gate.sh" \
    GATE_THEN_LAND_JOURNAL="$JOURNAL" WORKTREE_EXTEND_JOURNAL="$JOURNAL" \
    "$GATE_THEN_LAND" "$REPO" ac8-slug minor /dev/null >"$out" 2>"$out.err"
rc=$?

expect "AC8: gate-then-land.sh exits 12 (contended)" "[ $rc -eq 12 ]"
expect "AC8: stderr names producer-lock-contended" "grep -q 'producer-lock-contended' \"$out.err\""
expect "AC8: the underlying gate was invoked exactly once (no retry on top of extend-gate.sh's own wait)" \
  "[ \"\$(wc -l < \"$CALL_LOG\")\" -eq 1 ]"
expect "AC8: journal has exactly one 'contended' line" "[ \"\$(grep -c contended \"$JOURNAL\")\" -eq 1 ]"
expect "AC8: journal never says block/gate-block/gate-red/verdict=block for this run" \
  "! grep -qE 'block|gate-red' \"$JOURNAL\""
expect "AC8: no land-retries-exhausted line (this isn't a stale-base exhaustion)" \
  "! grep -q land-retries-exhausted \"$JOURNAL\""

echo "-----"
if [ "$gatepat_fail" -eq 0 ]; then
  echo "gatepat_ac8: ALL PASS"
  exit 0
else
  echo "gatepat_ac8: assertion(s) FAILED"
  exit 1
fi
