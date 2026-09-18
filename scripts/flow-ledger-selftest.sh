#!/usr/bin/env bash
# flow-ledger-selftest.sh — PRD-build-flow-ledger AC1/AC2/AC3.
# Never touches production state: FLOW_LEDGER_FILE and BUILD_JOURNAL_ROOT
# are pinned to scratch dirs under /tmp for every scenario below.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FL="$HERE/flow-ledger.sh"
LC="$HERE/lane-claim.sh"

ROOT=$(mktemp -d /tmp/flow-ledger-selftest.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

# =======================================================================
# AC1 + AC2 — a fixture run's eight events, in order, with a verdict on
# each gate_verdict, and a report whose lead_time/wait_time/gate_time/
# gate_runs/blocks match the fixture timestamps.
# =======================================================================
echo "== AC1: eight ordered events, verdict on each gate_verdict =="
LEDGER="$ROOT/flow-ledger.jsonl"
python3 - "$LEDGER" <<'PY'
import json, sys, datetime
path = sys.argv[1]
t0 = datetime.datetime(2026, 9, 18, 0, 0, 0)
def ts(mins):
    return (t0 + datetime.timedelta(minutes=mins)).strftime("%Y-%m-%dT%H:%M:%SZ")
events = [
  {"ts": ts(0),  "slug": "fixture-slug", "stage": "queued",       "lane": "redbaron"},
  {"ts": ts(10), "slug": "fixture-slug", "stage": "claimed",      "lane": "redbaron"},
  {"ts": ts(20), "slug": "fixture-slug", "stage": "gate_start",   "lane": "redbaron"},
  {"ts": ts(30), "slug": "fixture-slug", "stage": "gate_verdict", "lane": "redbaron", "detail": "verdict=block"},
  {"ts": ts(40), "slug": "fixture-slug", "stage": "gate_start",   "lane": "redbaron"},
  {"ts": ts(55), "slug": "fixture-slug", "stage": "gate_verdict", "lane": "redbaron", "detail": "verdict=pass"},
  {"ts": ts(60), "slug": "fixture-slug", "stage": "landed",       "lane": "redbaron"},
  {"ts": ts(65), "slug": "fixture-slug", "stage": "archived",     "lane": "redbaron"},
]
with open(path, "w") as f:
    for e in events:
        f.write(json.dumps(e) + "\n")
PY
[ "$(wc -l < "$LEDGER")" -eq 8 ] || fail "expected 8 events, got $(wc -l < "$LEDGER")"
stages="$(jq -r '.stage' "$LEDGER" | paste -sd, -)"
[ "$stages" = "queued,claimed,gate_start,gate_verdict,gate_start,gate_verdict,landed,archived" ] \
  || fail "stage order: $stages"
verdicts="$(jq -r 'select(.stage=="gate_verdict") | .detail' "$LEDGER" | paste -sd, -)"
[ "$verdicts" = "verdict=block,verdict=pass" ] || fail "gate_verdict details: $verdicts"
slugs="$(jq -r '.slug' "$LEDGER" | sort -u)"
[ "$slugs" = "fixture-slug" ] || fail "not all events share one slug: $slugs"
echo ok

echo "== AC2: report --slug matches the fixture timestamps =="
out="$(FLOW_LEDGER_FILE="$LEDGER" "$FL" report --slug fixture-slug --format json)"
echo "$out" | jq -e '.lead_time_h == (65/60)' >/dev/null || fail "lead_time_h: $out"
echo "$out" | jq -e '.wait_time_s == 900' >/dev/null || fail "wait_time_s: $out"
echo "$out" | jq -e '.gate_time_s == 1500' >/dev/null || fail "gate_time_s: $out"
echo "$out" | jq -e '.gate_runs == 2' >/dev/null || fail "gate_runs: $out"
echo "$out" | jq -e '.blocks == 1' >/dev/null || fail "blocks: $out"
echo ok

# =======================================================================
# AC3 — an unwritable ledger path never blocks lane-claim.sh claim, and
# one journal line names the failure.
# =======================================================================
echo "== AC3: unwritable ledger path -- claim still succeeds =="
git init -q --bare "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$ROOT/clone"
mkdir -p "$ROOT/clone/build-queue"
cat > "$ROOT/clone/build-queue/PRD-ac3-smoke.md" <<'EOF'
# PRD: ac3-smoke

- Status: queued
- build_target: shell
- build_into: /tmp/some-target-repo
- build_priority: high
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$ROOT/clone" push -q origin master 2>/dev/null || git -C "$ROOT/clone" push -q origin main 2>/dev/null || true
PRD="$ROOT/clone/build-queue/PRD-ac3-smoke.md"

RO_DIR="$ROOT/readonly"
mkdir -p "$RO_DIR"
chmod 000 "$RO_DIR"
JOURNAL_SCRATCH="$ROOT/journal"

set +e
out=$(FLOW_LEDGER_FILE="$RO_DIR/sub/flow-ledger.jsonl" BUILD_JOURNAL_ROOT="$JOURNAL_SCRATCH" \
  "$LC" claim "$PRD" redbaron 2>&1)
rc=$?
set -e
chmod 755 "$RO_DIR"
[ "$rc" -eq 0 ] || fail "claim did not succeed with an unwritable ledger path (rc=$rc): $out"
echo "$out" | grep -q '^claimed: ac3-smoke lane=redbaron' || fail "claim output: $out"
grep -rq 'flow-ledger append-failed' "$JOURNAL_SCRATCH" 2>/dev/null \
  || fail "no journal line naming the ledger failure ($JOURNAL_SCRATCH)"
echo ok

# =======================================================================
# AC4 — manifest-set.sh receives ticks_invested_delta: 1; ticks_invested
# ends up equal to the ledger's own claimed-count for the slug, and one
# journal line says the delta was ignored.
# =======================================================================
echo "== AC4: ticks_invested_delta is ignored, ticks_invested derived from the ledger =="
MS="$HERE/manifest-set.sh"
AC4_STATE=$(mktemp -d /tmp/flow-ledger-ac4-state.XXXXXX)
AC4_LEDGER="$AC4_STATE/flow-ledger.jsonl"
AC4_JOURNAL="$AC4_STATE/journal/$(date -u +%F).md"
for i in 1 2 3; do
  printf '{"ts":"2026-09-18T00:0%s:00Z","slug":"ac4-slug","stage":"claimed","lane":"redbaron"}\n' "$i" >> "$AC4_LEDGER"
done

patch_file="$AC4_STATE/patch.json"
echo '{"ticks_invested_delta": 1}' > "$patch_file"

BUILD_STATE_DIR="$AC4_STATE" FLOW_LEDGER_FILE="$AC4_LEDGER" JOURNAL="$AC4_JOURNAL" \
  "$MS" ac4-slug "$patch_file"
rc=$?
[ "$rc" -eq 0 ] || fail "manifest-set exited $rc"
ticks="$(jq -r '.prds[] | select(.slug=="ac4-slug") | .ticks_invested' "$AC4_STATE/manifest.json")"
[ "$ticks" = "3" ] || fail "ticks_invested: got '$ticks', want 3 (ledger's claimed count)"
jq -e 'has("ticks_invested_delta") | not' <(jq '.prds[] | select(.slug=="ac4-slug")' "$AC4_STATE/manifest.json") >/dev/null \
  || fail "ticks_invested_delta leaked into the manifest entry"
grep -q 'ticks-invested-delta-ignored' "$AC4_JOURNAL" || fail "no journal line saying the delta was ignored"
rm -rf "$AC4_STATE"
echo ok

echo "flow-ledger-selftest: PASS"
