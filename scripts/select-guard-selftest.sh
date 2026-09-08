#!/usr/bin/env bash
# select-guard-selftest.sh — exercises select-guard.sh's dispatch-boundary
# check against scratch repos under /tmp/. Never touches the real
# ~/Documents/PRDs clone.
#
# Reproduces this PRD's own triggering scenario (PRD-autobuilder-gate-debt,
# 2026-09-08): a live foreign-lane claim on the candidate's build_into repo,
# one candidate PRD up for selection — the guard must block it (AC1), and
# once that same claim goes stale (>=3h old) the guard must admit the
# candidate again (AC2).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SG="$HERE/select-guard.sh"
LC="$HERE/lane-claim.sh"
ROOT=$(mktemp -d /tmp/select-guard-selftest.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

git init -q --bare "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$ROOT/clone"
mkdir -p "$ROOT/clone/build-queue"

cat > "$ROOT/clone/build-queue/PRD-victim.md" <<'EOF'
# PRD: victim — the candidate this tick wants to dispatch into

- Status: queued
- build_target: shell
- build_into: /tmp/select-guard-target-repo
EOF

cat > "$ROOT/clone/build-queue/PRD-holder.md" <<'EOF'
# PRD: holder — shares victim's build_into, claimed by a foreign lane

- Status: queued
- build_target: shell
- build_into: /tmp/select-guard-target-repo
EOF

git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m init
BRANCH=$(git -C "$ROOT/clone" symbolic-ref --short HEAD)
git -C "$ROOT/clone" push -q origin "$BRANCH"

VICTIM="$ROOT/clone/build-queue/PRD-victim.md"
HOLDER="$ROOT/clone/build-queue/PRD-holder.md"

echo "== no claim on the target repo: guard admits the candidate =="
out=$("$SG" victim carbon "$ROOT/clone")
echo "$out" | grep -q '^ok: victim:' || { echo "FAIL: $out"; exit 1; }
echo ok

echo "== AC1: a live foreign-lane claim on build_into blocks dispatch, loudly =="
"$LC" claim "$HOLDER" redbaron >/dev/null
set +e
out=$("$SG" victim carbon "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected exit 1, got $rc: $out"; exit 1; }
echo "$out" | grep -q '^blocked: victim:' || { echo "FAIL msg prefix: $out"; exit 1; }
echo "$out" | grep -q 'busy:' || { echo "FAIL: message does not name the busy claim: $out"; exit 1; }
echo "$out" | grep -q 'holder' || { echo "FAIL: message does not name the holding slug: $out"; exit 1; }
echo ok

echo "== AC4: usage error surfaces via lane-predicate's own path (composition, not reimplementation) =="
set +e
out=$("$SG" no-such-slug carbon "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 4 ] || { echo "FAIL expected exit 4 for missing PRD, got $rc: $out"; exit 1; }
echo ok

echo "== AC2: once the same claim goes stale (>=3h), the guard admits the candidate again =="
python3 - "$HOLDER" <<'PYEOF'
import re, sys
f = sys.argv[1]
with open(f) as fh:
    text = fh.read()
text = re.sub(r'^- Lane:.*$', '- Lane: redbaron 2020-01-01T00:00:00Z', text, flags=re.M)
with open(f, 'w') as fh:
    fh.write(text)
PYEOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m stale-the-claim
git -C "$ROOT/clone" push -q origin "$BRANCH"

out=$("$SG" victim carbon "$ROOT/clone")
echo "$out" | grep -q '^ok: victim:' || { echo "FAIL expected ok on stale claim, got: $out"; exit 1; }
echo ok

echo "ALL PASS"
