#!/usr/bin/env bash
# lane-status-selftest.sh — exercises lane-status.sh's tick-summary (journal
# append) and report (last-tick-per-lane + live claims) paths against
# scratch dirs under /tmp/. Never touches the real journal or PRD clone.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LS="$HERE/lane-status.sh"
LC="$HERE/lane-claim.sh"
ROOT=$(mktemp -d /tmp/lane-status-selftest.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

JOURNAL_DIR="$ROOT/journal"
mkdir -p "$JOURNAL_DIR"
TODAY=$(date -u +%F)
JOURNAL="$JOURNAL_DIR/$TODAY.md"

echo "== tick-summary appends a well-formed line =="
out=$("$LS" tick-summary RedBaron 3 1 "$JOURNAL")
echo "$out" | grep -q "^appended: $JOURNAL" || { echo "FAIL: $out"; exit 1; }
grep -q 'lane-health  tick  claimed=3 skipped=1  (lane=RedBaron)' "$JOURNAL" || { echo "FAIL journal content"; cat "$JOURNAL"; exit 1; }
echo ok

echo "== second lane's line also appended, both surface in report =="
"$LS" tick-summary carbon 2 0 "$JOURNAL" >/dev/null

git init -q --bare "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$ROOT/clone"
mkdir -p "$ROOT/clone/build-queue"
cat > "$ROOT/clone/build-queue/PRD-smoke.md" <<'EOF'
# PRD: smoke

- Status: queued
- build_target: shell
- build_into: /tmp/some-target
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$ROOT/clone" push -q origin master 2>/dev/null || git -C "$ROOT/clone" push -q origin main 2>/dev/null || true
"$LC" claim "$ROOT/clone/build-queue/PRD-smoke.md" RedBaron >/dev/null

out=$("$LS" report --prd-dir "$ROOT/clone" --journal-dir "$JOURNAL_DIR" --days 1)
echo "$out" | grep -q 'RedBaron: .*claimed=3 skipped=1' || { echo "FAIL RedBaron line missing:"; echo "$out"; exit 1; }
echo "$out" | grep -q 'carbon: .*claimed=2 skipped=0' || { echo "FAIL carbon line missing:"; echo "$out"; exit 1; }
echo "$out" | grep -q '^PRD-smoke: RedBaron ' || { echo "FAIL live claim missing:"; echo "$out"; exit 1; }
echo ok

echo "ALL PASS"
