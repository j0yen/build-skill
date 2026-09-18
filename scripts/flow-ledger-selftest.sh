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

# =======================================================================
# AC5 — a day with three archived PRDs: day-ledger.sh's JSON has
# flow.lead_time_p50_h and flow.prds_measured = 3, schema = build.day_ledger.v2.
# =======================================================================
echo "== AC5: day-ledger.sh flow{} block over three archived PRDs =="
DL="$HERE/day-ledger.sh"
AC5_STATE=$(mktemp -d /tmp/flow-ledger-ac5-state.XXXXXX)
AC5_LEDGER="$AC5_STATE/flow-ledger.jsonl"
AC5_DATE="2030-07-01"
python3 - "$AC5_LEDGER" "$AC5_DATE" <<'PY'
import json, sys, datetime
path, day = sys.argv[1], sys.argv[2]
t0 = datetime.datetime.strptime(day, "%Y-%m-%d")
def ts(mins):
    return (t0 + datetime.timedelta(minutes=mins)).strftime("%Y-%m-%dT%H:%M:%SZ")
events = []
for i, slug in enumerate(["ac5-slug-a", "ac5-slug-b", "ac5-slug-c"]):
    base = i * 10
    events += [
        {"ts": ts(base + 0),  "slug": slug, "stage": "queued",       "lane": "redbaron"},
        {"ts": ts(base + 5),  "slug": slug, "stage": "claimed",      "lane": "redbaron"},
        {"ts": ts(base + 10), "slug": slug, "stage": "gate_start",   "lane": "redbaron"},
        {"ts": ts(base + 20), "slug": slug, "stage": "gate_verdict", "lane": "redbaron", "detail": "verdict=pass"},
        {"ts": ts(base + 25), "slug": slug, "stage": "landed",       "lane": "redbaron"},
        {"ts": ts(base + 30), "slug": slug, "stage": "archived",     "lane": "redbaron"},
    ]
with open(path, "w") as f:
    for e in events:
        f.write(json.dumps(e) + "\n")
PY
AC5_OUT="$AC5_STATE/day-ledger.json"
# day-ledger.sh's day window is [target_date 00:00, +1day) in America/New_York,
# not UTC -- derive which NY calendar date the fixture's first UTC
# timestamp ($AC5_DATE 00:00:00Z) actually falls on, rather than
# hand-computing the TZ offset (and risking an off-by-one across a DST
# transition).
AC5_FIRST_EPOCH="$(date -u -d "${AC5_DATE}T00:00:00Z" +%s)"
AC5_TZ_DATE="$(TZ="America/New_York" date -d "@$AC5_FIRST_EPOCH" +%F)"
PRD_DIR="$AC5_STATE/no-such-prd-dir" DAY_LEDGER_FLOW_LEDGER_FILE="$AC5_LEDGER" \
  "$DL" --date "$AC5_TZ_DATE" --no-push --out "$AC5_OUT" >/dev/null 2>&1
[ -s "$AC5_OUT" ] || fail "day-ledger.sh produced no output file"
schema="$(jq -r '.schema' "$AC5_OUT")"
[ "$schema" = "build.day_ledger.v2" ] || fail "AC5 schema: got '$schema', want build.day_ledger.v2"
measured="$(jq -r '.flow.prds_measured' "$AC5_OUT")"
[ "$measured" = "3" ] || fail "AC5 flow.prds_measured: got '$measured', want 3"
jq -e '.flow.lead_time_p50_h | type == "number"' "$AC5_OUT" >/dev/null \
  || fail "AC5 flow.lead_time_p50_h missing or not a number: $(jq -c .flow "$AC5_OUT")"
rm -rf "$AC5_STATE"
echo ok

# =======================================================================
# Requirement 2 — manifest-set.sh is the named writer for blocked/
# unblocked: a patch that SETS blockers (empty/absent -> non-empty) fires
# `blocked`; a patch that CLEARS them (non-empty -> empty) fires
# `unblocked`; a patch that doesn't touch `blockers` at all fires neither.
# =======================================================================
echo "== Requirement 2: manifest-set.sh fires blocked/unblocked on blockers set/clear =="
BLK_STATE=$(mktemp -d /tmp/flow-ledger-blk-state.XXXXXX)
BLK_LEDGER="$BLK_STATE/flow-ledger.jsonl"
echo '{"prds":[{"slug":"blk-smoke","status":"queued"}]}' > "$BLK_STATE/manifest.json"
echo '{"blockers":["waiting on X"]}' > "$BLK_STATE/p-block.json"
echo '{"blockers":[]}' > "$BLK_STATE/p-unblock.json"
echo '{"status":"queued"}' > "$BLK_STATE/p-untouched.json"
run_ms() { BUILD_STATE_DIR="$BLK_STATE" FLOW_LEDGER_FILE="$BLK_LEDGER" JOURNAL="$BLK_STATE/journal.md" "$MS" "$@"; }
run_ms blk-smoke "$BLK_STATE/p-block.json" >/dev/null
run_ms blk-smoke "$BLK_STATE/p-untouched.json" >/dev/null
run_ms blk-smoke "$BLK_STATE/p-unblock.json" >/dev/null
stages="$(jq -r '.stage' "$BLK_LEDGER" | paste -sd, -)"
[ "$stages" = "blocked,unblocked" ] || fail "blocked/unblocked stages: got '$stages', want 'blocked,unblocked' (an untouched-blockers patch must fire neither)"
rm -rf "$BLK_STATE"
echo ok

# =======================================================================
# Requirement 2 — mark-needs-classification.sh is the named writer for
# the `needs_classification` stage, fired once the commit is durably
# pushed (same "only after the postcondition holds" convention
# archive-commit.sh's own `archived` write already uses).
# =======================================================================
echo "== Requirement 2: mark-needs-classification.sh fires needs_classification =="
MNC="$HERE/mark-needs-classification.sh"
NC_ROOT=$(mktemp -d /tmp/flow-ledger-nc-state.XXXXXX)
git init -q --bare "$NC_ROOT/origin.git"
git clone -q "$NC_ROOT/origin.git" "$NC_ROOT/clone"
mkdir -p "$NC_ROOT/clone/build-queue"
cat > "$NC_ROOT/clone/build-queue/PRD-nc-smoke.md" <<'EOF'
# PRD: nc-smoke

- Status: queued
- build_target: shell
- build_into: /tmp/some-target-repo
- build_priority: high
EOF
git -C "$NC_ROOT/clone" add -A
git -C "$NC_ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$NC_ROOT/clone" push -q origin master 2>/dev/null || git -C "$NC_ROOT/clone" push -q origin main 2>/dev/null || true
NC_LEDGER="$NC_ROOT/flow-ledger.jsonl"
NC_JOURNAL="$NC_ROOT/journal"
out="$(FLOW_LEDGER_FILE="$NC_LEDGER" BUILD_JOURNAL_ROOT="$NC_JOURNAL" \
  "$MNC" "$NC_ROOT/clone/build-queue/PRD-nc-smoke.md" "operator judgment call, no lint id" --force 2>&1)"
echo "$out" | grep -q '^needs-classification-committed: nc-smoke' || fail "mark-needs-classification output: $out"
nc_hits="$(jq -c 'select(.slug=="nc-smoke" and .stage=="needs_classification")' "$NC_LEDGER" 2>/dev/null | wc -l)"
[ "$nc_hits" = 1 ] || fail "needs_classification event: got $nc_hits, want 1 ($(cat "$NC_LEDGER" 2>/dev/null))"
rm -rf "$NC_ROOT"
echo ok

# =======================================================================
# AC7 (P1) — given PRDs archived within a --since window, backfill gives
# every one an `archived` event marked source=backfill, and the report's
# lead_time p50 is within 10% of the 2026-09-18 hand analysis (6h).
# lead_time = queued(Drafted: date, midnight UTC) -> archived(the "archive:
# <slug> shipped" commit's own author date) -- 5 fixture PRDs at 4h, 5h,
# 6h, 7h, 8h apart (median = 6h exactly) proves both the reconstruction
# and the report math, without needing a journal fixture at all (gate_*
# reconstruction is out of scope -- see flow-ledger.sh's own backfill
# docstring -- and lead_time never touches gate events).
# =======================================================================
echo "== AC7: backfill -- archived event + lead_time p50 within 10% of 6h =="
BF_ROOT=$(mktemp -d /tmp/flow-ledger-ac7.XXXXXX)
BF_PRDS="$BF_ROOT/prds"
mkdir -p "$BF_PRDS/built-prds"
git init -q "$BF_PRDS"
BF_LEDGER="$BF_ROOT/flow-ledger.jsonl"
BF_JOURNAL="$BF_ROOT/journal"
# flow-ledger.sh's --since is relative to the REAL clock (same convention
# report --since already uses), so the fixture's own archive-commit dates
# are pinned a few days back from wall-clock now, well inside a 14d window.
REAL_NOW_EP="$(date -u +%s)"
BF_DATE="$(date -u -d "@$((REAL_NOW_EP - 5 * 86400))" +%F)"
i=0
for h in 4 5 6 7 8; do
  slug="ac7-slug-$i"
  cat > "$BF_PRDS/built-prds/PRD-$slug.md" <<EOF
# PRD: $slug

- Status: built
- Drafted: $BF_DATE
- Lane: redbaron ${BF_DATE}T00:30:00Z
EOF
  git -C "$BF_PRDS" add -A
  git -C "$BF_PRDS" -c user.name=t -c user.email=t@t commit -q -m "wip $slug"
  GIT_AUTHOR_DATE="${BF_DATE}T$(printf '%02d' "$h"):00:00Z" GIT_COMMITTER_DATE="${BF_DATE}T$(printf '%02d' "$h"):00:00Z" \
    git -C "$BF_PRDS" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "archive: $slug shipped"
  i=$((i + 1))
done
rm -f "$BF_LEDGER"
bf_out="$(FLOW_LEDGER_FILE="$BF_LEDGER" BUILD_JOURNAL_ROOT="$BF_JOURNAL" \
  "$FL" backfill --since 14d --prd-dir "$BF_PRDS" 2>&1)"
echo "$bf_out" | grep -qE 'archived=5 ' || fail "AC7 backfill summary: $bf_out"
for i in 0 1 2 3 4; do
  hits="$(jq -c --arg s "ac7-slug-$i" 'select(.slug==$s and .stage=="archived" and (.detail|contains("source=backfill")))' "$BF_LEDGER" 2>/dev/null | wc -l)"
  [ "$hits" = 1 ] || fail "AC7: ac7-slug-$i missing a source=backfill archived event"
done
rep="$(FLOW_LEDGER_FILE="$BF_LEDGER" "$FL" report --format json)"
p50="$(printf '%s' "$rep" | jq -r '.lead_time_p50_h')"
python3 -c "
p50 = float('$p50')
want = 6.0
tol = want * 0.10
assert abs(p50 - want) <= tol, f'p50={p50} not within 10% of {want}'
" || fail "AC7 lead_time p50: got $p50, want ~6h (+/-10%)"
measured="$(printf '%s' "$rep" | jq -r '.prds_measured')"
[ "$measured" = "5" ] || fail "AC7 prds_measured: got $measured, want 5"
# idempotent: a second backfill run over the same window adds nothing new
bf_out2="$(FLOW_LEDGER_FILE="$BF_LEDGER" BUILD_JOURNAL_ROOT="$BF_JOURNAL" \
  "$FL" backfill --since 14d --prd-dir "$BF_PRDS" 2>&1)"
echo "$bf_out2" | grep -qE 'archived=0 ' || fail "AC7 idempotency: second run: $bf_out2"
rm -rf "$BF_ROOT"
echo ok

echo "flow-ledger-selftest: PASS"
