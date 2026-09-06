#!/usr/bin/env bash
# lane-predicate-selftest.sh — exercises lane-predicate.sh's select/reachable
# paths (cargo-free pass, cargo-bound skip on carbon, RedBaron unrestricted,
# target-busy skip, unreachable origin) against scratch repos under /tmp/.
# Never touches the real ~/Documents/PRDs clone.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LP="$HERE/lane-predicate.sh"
ROOT=$(mktemp -d /tmp/lane-predicate-selftest.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

git init -q --bare "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$ROOT/clone"
mkdir -p "$ROOT/clone/build-queue"

cat > "$ROOT/clone/build-queue/PRD-shell-one.md" <<'EOF'
# PRD: shell-one

- Status: queued
- build_target: shell
- build_into: /tmp/target-repo-a
EOF

cat > "$ROOT/clone/build-queue/PRD-rust-one.md" <<'EOF'
# PRD: rust-one

- Status: queued
- build_target: rust-extend
- build_into: /tmp/target-repo-b
EOF

git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$ROOT/clone" push -q origin master 2>/dev/null || git -C "$ROOT/clone" push -q origin main 2>/dev/null || true

SHELL_PRD="$ROOT/clone/build-queue/PRD-shell-one.md"
RUST_PRD="$ROOT/clone/build-queue/PRD-rust-one.md"

echo "== carbon lane: cargo-free PRD selectable =="
out=$("$LP" select "$SHELL_PRD" carbon)
echo "$out" | grep -q '^ok: lane=carbon build_target=shell' || { echo "FAIL: $out"; exit 1; }
echo ok

echo "== carbon lane: cargo-bound PRD skipped =="
set +e
out=$("$LP" select "$RUST_PRD" carbon 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected exit 1, got $rc: $out"; exit 1; }
echo "$out" | grep -q '^skip: cargo-bound build_target=rust-extend' || { echo "FAIL msg: $out"; exit 1; }
echo ok

echo "== RedBaron lane: cargo-bound PRD still selectable (unrestricted) =="
out=$("$LP" select "$RUST_PRD" RedBaron)
echo "$out" | grep -q '^ok: lane=RedBaron build_target=rust-extend' || { echo "FAIL: $out"; exit 1; }
echo ok

echo "== target exclusivity: a live claim on build_into blocks the other lane =="
LC="$HERE/lane-claim.sh"
"$LC" claim "$RUST_PRD" RedBaron >/dev/null
set +e
out=$("$LP" select "$RUST_PRD" carbon 2>&1); rc=$?
set -e
# carbon would already skip on cargo-bound, so prove exclusivity independently
# against a cargo-free PRD sharing the busy target.
cat > "$ROOT/clone/build-queue/PRD-shell-two.md" <<EOF
# PRD: shell-two

- Status: queued
- build_target: shell
- build_into: /tmp/target-repo-b
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m add-shell-two
git -C "$ROOT/clone" push -q origin "$(git -C "$ROOT/clone" symbolic-ref --short HEAD)"
SHELL_TWO="$ROOT/clone/build-queue/PRD-shell-two.md"
set +e
out=$("$LP" select "$SHELL_TWO" carbon "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected exit 1 (target busy), got $rc: $out"; exit 1; }
echo "$out" | grep -q '^skip: busy:' || { echo "FAIL busy msg: $out"; exit 1; }
echo ok

echo "== reachable: valid origin =="
out=$("$LP" reachable "$ROOT/clone")
[ "$out" = "reachable" ] || { echo "FAIL: $out"; exit 1; }
echo ok

echo "== reachable: broken origin =="
BROKEN=$(mktemp -d /tmp/lane-predicate-broken.XXXXXX)
git init -q "$BROKEN"
git -C "$BROKEN" remote add origin /tmp/does-not-exist-$$.git
set +e
out=$("$LP" reachable "$BROKEN" 2>&1); rc=$?
set -e
rm -rf "$BROKEN"
[ "$rc" -eq 1 ] || { echo "FAIL expected exit 1, got $rc: $out"; exit 1; }
[ "$out" = "unreachable" ] || { echo "FAIL: $out"; exit 1; }
echo ok

echo "ALL PASS"
