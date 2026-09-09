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

echo "== ryzen7 lane: cargo-bound PRD selectable (not in CARGO_FREE_LANES roster) =="
out=$("$LP" select "$RUST_PRD" ryzen7)
echo "$out" | grep -q '^ok: lane=ryzen7 build_target=rust-extend' || { echo "FAIL: $out"; exit 1; }
echo ok

echo "== carbon lane: still rejected for the same rust-extend PRD (roster unchanged) =="
set +e
out=$("$LP" select "$RUST_PRD" carbon 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected exit 1, got $rc: $out"; exit 1; }
echo "$out" | grep -q '^skip: cargo-bound build_target=rust-extend' || { echo "FAIL msg: $out"; exit 1; }
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

echo "== same-lane sub-cap: 1-2 live same-lane claims admit the candidate; a 3rd is skipped naming the sub-cap, not generic busy (AC3) =="
cat > "$ROOT/clone/build-queue/PRD-cap-a.md" <<EOF
# PRD: cap-a

- Status: queued
- build_target: shell
- build_into: /tmp/target-repo-c
EOF
cat > "$ROOT/clone/build-queue/PRD-cap-b.md" <<EOF
# PRD: cap-b

- Status: queued
- build_target: shell
- build_into: /tmp/target-repo-c
EOF
cat > "$ROOT/clone/build-queue/PRD-cap-c.md" <<EOF
# PRD: cap-c

- Status: queued
- build_target: shell
- build_into: /tmp/target-repo-c
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m add-cap-prds
git -C "$ROOT/clone" push -q origin "$(git -C "$ROOT/clone" symbolic-ref --short HEAD)"

CAP_A="$ROOT/clone/build-queue/PRD-cap-a.md"
CAP_B="$ROOT/clone/build-queue/PRD-cap-b.md"
CAP_C="$ROOT/clone/build-queue/PRD-cap-c.md"

"$LC" claim "$CAP_A" RedBaron >/dev/null
out=$("$LP" select "$CAP_B" RedBaron "$ROOT/clone")
echo "$out" | grep -q '^ok:' || { echo "FAIL expected ok with 1 same-lane claim live, got: $out"; exit 1; }
echo ok

"$LC" claim "$CAP_B" RedBaron >/dev/null
out=$("$LP" select "$CAP_C" RedBaron "$ROOT/clone")
echo "$out" | grep -q '^ok:' || { echo "FAIL expected ok with 2 same-lane claims live, got: $out"; exit 1; }
echo ok

"$LC" claim "$CAP_C" RedBaron >/dev/null
cat > "$ROOT/clone/build-queue/PRD-cap-d.md" <<EOF
# PRD: cap-d

- Status: queued
- build_target: shell
- build_into: /tmp/target-repo-c
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m add-cap-d
git -C "$ROOT/clone" push -q origin "$(git -C "$ROOT/clone" symbolic-ref --short HEAD)"
CAP_D="$ROOT/clone/build-queue/PRD-cap-d.md"
set +e
out=$("$LP" select "$CAP_D" RedBaron "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected exit 1 (sub-cap), got $rc: $out"; exit 1; }
echo "$out" | grep -q '^skip: sub-cap:' || { echo "FAIL expected sub-cap skip msg, got: $out"; exit 1; }
echo ok

echo "== own-claim continuation: each of the 3 already-live claims is STILL selectable as a resume, even sitting at the sub-cap (PRD-build-claims-resume-not-count, AC1/AC2) =="
# This is the exact 06:23Z OOM shape: 3 same-lane claims already sit at the
# sub-cap (set up above), so a brand-new cap-d is rightly skipped — but
# cap-a/b/c, which ARE those 3 claims, must never be skipped by the count
# they themselves make up.
for cap_prd in "$CAP_A" "$CAP_B" "$CAP_C"; do
  out=$("$LP" select "$cap_prd" RedBaron "$ROOT/clone")
  echo "$out" | grep -q '^ok: lane=RedBaron build_target=shell resume=own-claim$' \
    || { echo "FAIL expected resume=own-claim for $cap_prd, got: $out"; exit 1; }
done
echo ok

echo "== the 4th (never-claimed) candidate is still sub-cap-blocked after re-checking the continuations above (AC2) =="
set +e
out=$("$LP" select "$CAP_D" RedBaron "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected exit 1 (sub-cap), got $rc: $out"; exit 1; }
echo "$out" | grep -q '^skip: sub-cap:' || { echo "FAIL expected sub-cap skip msg, got: $out"; exit 1; }
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
