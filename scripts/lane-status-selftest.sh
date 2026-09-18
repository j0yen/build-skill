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

# PRD-build-flow-ledger requirement 7 / AC8: lane-status.sh report's new
# flow{} section shells out to flow-ledger.sh, which defaults to the REAL
# production ledger when FLOW_LEDGER_FILE/BUILD_STATE_DIR are unset --
# pin it to a scratch path so every `report` call below is isolated
# (never reads production state) and deterministic.
export FLOW_LEDGER_FILE="$ROOT/flow-ledger.jsonl"

JOURNAL_DIR="$ROOT/journal"
mkdir -p "$JOURNAL_DIR"
TODAY=$(date -u +%F)
JOURNAL="$JOURNAL_DIR/$TODAY.md"

echo "== tick-summary appends a well-formed line =="
out=$("$LS" tick-summary RedBaron 3 1 "$JOURNAL")
echo "$out" | grep -q "^appended: $JOURNAL" || { echo "FAIL: $out"; exit 1; }
grep -q 'lane-health  tick  claimed=3 skipped=1  (lane=RedBaron)' "$JOURNAL" || { echo "FAIL journal content"; cat "$JOURNAL"; exit 1; }
echo ok

echo "== tick-summary appends a JOURNAL: fixture_lines_today= line =="
grep -qE 'lane-health  JOURNAL: fixture_lines_today=[0-9]+' "$JOURNAL" || { echo "FAIL: no JOURNAL: fixture_lines_today= line"; cat "$JOURNAL"; exit 1; }
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

echo "== AC8: report prints the last-24h flow medians line =="
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$FLOW_LEDGER_FILE" "$NOW_ISO" <<'PY'
import json, sys, datetime
path, now_iso = sys.argv[1], sys.argv[2]
now = datetime.datetime.strptime(now_iso, "%Y-%m-%dT%H:%M:%SZ")
def ts(mins):
    return (now - datetime.timedelta(minutes=mins)).strftime("%Y-%m-%dT%H:%M:%SZ")
events = [
  {"ts": ts(300), "slug": "ls-flow-smoke", "stage": "queued", "lane": "redbaron"},
  {"ts": ts(240), "slug": "ls-flow-smoke", "stage": "claimed", "lane": "redbaron"},
  {"ts": ts(60),  "slug": "ls-flow-smoke", "stage": "landed", "lane": "redbaron"},
  {"ts": ts(30),  "slug": "ls-flow-smoke", "stage": "archived", "lane": "redbaron"},
]
with open(path, "w") as f:
    for e in events:
        f.write(json.dumps(e) + "\n")
PY
out2=$("$LS" report --prd-dir "$ROOT/clone" --journal-dir "$JOURNAL_DIR" --days 1)
echo "$out2" | grep -qE '^flow: prds_measured=1 lead_time_p50=[0-9.]+h p90=[0-9.]+h wait_p50=[0-9]+s gate_p50=[0-9]+s$' \
  || { echo "FAIL: no flow medians line:"; echo "$out2"; exit 1; }
echo ok

echo "== AC12 (PRD-build-prd-superseded-by): report prints superseded=<n> =="
cat > "$ROOT/clone/build-queue/PRD-sby-chain-a-pred.md" <<'EOF'
- Status: queued
- build_target: shell
- Superseded-by: PRD-sby-chain-a-succ.md
- transferred_acs: [1]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
cat > "$ROOT/clone/build-queue/PRD-sby-chain-a-succ.md" <<'EOF'
- Status: queued
- build_target: shell
- Absorbs: PRD-sby-chain-a-pred.md [1:1]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
cat > "$ROOT/clone/build-queue/PRD-sby-chain-b-pred.md" <<'EOF'
- Status: queued
- build_target: shell
- Superseded-by: PRD-sby-chain-b-succ.md
- transferred_acs: [1]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
cat > "$ROOT/clone/build-queue/PRD-sby-chain-b-succ.md" <<'EOF'
- Status: queued
- build_target: shell
- Absorbs: PRD-sby-chain-b-pred.md [1:1]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
out3=$("$LS" report --prd-dir "$ROOT/clone" --journal-dir "$JOURNAL_DIR" --days 1)
echo "$out3" | grep -qx 'superseded=2' \
  || { echo "FAIL: no superseded=2 line:"; echo "$out3"; exit 1; }
echo ok

echo "== AC14 (PRD-build-prd-superseded-by): digest prints+journals transferred-acs: <n> (<k> chains) =="
DIGEST_JOURNAL="$ROOT/digest.md"
out4=$("$LS" digest --prd-dir "$ROOT/clone" --journal "$DIGEST_JOURNAL")
echo "$out4" | grep -qx 'transferred-acs: 2 (2 chains)' \
  || { echo "FAIL: no transferred-acs: 2 (2 chains) line on stdout:"; echo "$out4"; exit 1; }
grep -qE 'transferred-acs: 2 \(2 chains\)' "$DIGEST_JOURNAL" \
  || { echo "FAIL: no transferred-acs line journaled"; cat "$DIGEST_JOURNAL"; exit 1; }
echo ok

echo "== digest on a corpus with no superseded chains prints 0 (0 chains) =="
EMPTY_ROOT=$(mktemp -d /tmp/lane-status-selftest-empty.XXXXXX)
mkdir -p "$EMPTY_ROOT/build-queue"
out5=$("$LS" digest --prd-dir "$EMPTY_ROOT" --journal "$ROOT/digest-empty.md")
echo "$out5" | grep -qx 'transferred-acs: 0 (0 chains)' \
  || { echo "FAIL: expected 0 (0 chains):"; echo "$out5"; exit 1; }
rm -rf "$EMPTY_ROOT"
echo ok

echo "ALL PASS"
