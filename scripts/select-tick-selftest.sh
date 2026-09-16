#!/usr/bin/env bash
# select-tick-selftest.sh — exercises select-tick.sh's whole pool-to-
# admitted transformation against scratch fixtures under /tmp/. Never
# touches the real ~/Documents/PRDs clone or the real shared journal.
#
# Unlike select-guard-selftest.sh's fixtures (which select-guard.sh reads
# directly, no lint), select-tick.sh's first step is a REAL
# scripts/scan-prds.sh call, which runs the real prd-lint.sh contract
# gate. Every fixture PRD here is written to actually PASS that gate
# (Status/build_target/Vision:/an `## Acceptance criteria` section with
# one leveled Given/When/Then line) rather than mocking scan-prds.sh out
# -- a fixture that can't pass real lint would make this selftest
# tautological.
#
# Covers: AC1 (burst sub-cap widening), AC2 (BUILD_DISTINCT_TARGETS=1
# same-target skip), AC3 (Depends-on waiting-on), AC4 (BUILD_MAX_BRANCHES
# cap), AC6 (journal line count + schema validation), AC7 (own-claim
# continuation admitted first, exempt from the same-target tally), AC10
# (--dry-run byte-identical, no journal write), and AC12's own requirement
# (at least one failure path — a guard exit 1 — asserted as a skip, never
# an admission: the cargo-bound case here).
#
# AC5 (process visibility is not an input) is not exercised with a fake
# process: requirement 3 means select-tick.sh contains no pgrep/ps/systemd
# code path to fool in the first place -- see select-tick.sh's own header.
# AC8 (SKILL.md rewrite) is a static grep check, not fixture-based; run
# separately (see build-select-tick-deterministic's build journal).
# AC9 (--explain) gets a light smoke check only, not full coverage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ST="$HERE/select-tick.sh"
SCHEMA="$HERE/select-tick.schema.json"
JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"

# PRD-build-journal-single-writer requirement 3: the structural prelude,
# sourced before select-tick.sh (or anything it shells out to, including
# select-guard.sh) ever runs. This selftest already isolates select-
# tick.sh's OWN journal via SELECT_TICK_JOURNAL below — what it never did
# before this PRD was isolate select-guard.sh's, which select-tick.sh
# calls internally and which reads a DIFFERENT env var
# (SELECT_GUARD_JOURNAL) that this file never set. selftest_init's
# BUILD_TEST=1 + BUILD_JOURNAL_ROOT is structural, so it covers
# select-guard.sh (and anything else this selftest transitively invokes)
# without this file needing to know every callee's own override name —
# exactly the 2026-09-15 leak this PRD exists to close.
# shellcheck source=lib/isolation.sh
source "$HERE/lib/isolation.sh"
selftest_init || { echo "select-tick-selftest: selftest_init failed" >&2; exit 1; }

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok: $*"; }

ROOT=$(mktemp -d /tmp/select-tick-selftest.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/build-queue" "$ROOT/built-prds" "$ROOT/visions" "$ROOT/state"
echo "# fixture vision" > "$ROOT/visions/fixture.md"
echo '{"prds":{}}' > "$ROOT/state/manifest.json"

# Never journals to the real shared journal (isolated per-run below via
# SELECT_TICK_JOURNAL, same convention as select-guard.sh's own
# SELECT_GUARD_JOURNAL override).
JOURNAL="$ROOT/journal.md"
: > "$JOURNAL"

# Fake burst-lane.sh: only rust-extend fixtures below ever ask it anything
# (select-guard.sh's own burst-widening gate). Controlled per-call via
# FAKE_BURST_READY/FAKE_BURST_WIDTH so different cases can flip it.
FAKE_BURST_READY=false
FAKE_BURST_WIDTH=8
FAKE_BURST="$ROOT/fake-burst-lane.sh"
cat > "$FAKE_BURST" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "status" ]; then
  printf '{"gate_ready":%s,"width":%s}\n' "${FAKE_BURST_READY:-false}" "${FAKE_BURST_WIDTH:-0}"
  exit 0
fi
echo '{}'
EOF
chmod +x "$FAKE_BURST"

run_select_tick() {
  BUILD_STATE_DIR="$ROOT/state" BUILD_MANIFEST="$ROOT/state/manifest.json" \
    SELECT_TICK_JOURNAL="$JOURNAL" \
    BURST_LANE_SH="$FAKE_BURST" \
    FAKE_BURST_READY="$FAKE_BURST_READY" FAKE_BURST_WIDTH="$FAKE_BURST_WIDTH" \
    "$ST" --prd-dir "$ROOT" "$@"
}

write_prd() {
  # write_prd <slug> [build_target] [build_into] [depends_on] [extra_frontmatter_lines...]
  local slug="$1" bt="${2:-shell}" bi="${3:-}" dep="${4:-}"
  {
    echo "# PRD: $slug"
    echo
    echo "- Status: queued"
    echo "- build_target: $bt"
    [ -n "$bi" ] && echo "- build_into: $bi"
    [ -n "$dep" ] && echo "- Depends-on: $dep"
    echo "- Vision: visions/fixture.md"
    echo
    echo "## Acceptance criteria"
    echo
    echo "1. P0 — Given a fixture, When select-tick runs, Then it is admitted or skipped deterministically."
  } > "$ROOT/build-queue/PRD-$slug.md"
}

clear_queue() { rm -f "$ROOT/build-queue"/PRD-*.md; }

# ============================================================================
echo "== AC1: 8 queued rust-extend PRDs, one build_into, burst sub-cap=8 =="
clear_queue
for i in 1 2 3 4 5 6 7 8; do
  write_prd "rext$i" rust-extend /tmp/select-tick-shared-repo
done
FAKE_BURST_READY=true FAKE_BURST_WIDTH=8
# select-guard.sh's own burst-widened cap is min(BUILD_SAME_TARGET_CAP_BURST
# (default 4), the reported width) -- BUILD_SAME_TARGET_CAP_BURST=8 here so
# a width=8 fixture actually reaches sub-cap=8 (default 4 would cap it there).
out=$(BUILD_DISTINCT_TARGETS=0 BUILD_MAX_BRANCHES=30 BUILD_SAME_TARGET_CAP_BURST=8 run_select_tick --format json)
admitted_n=$(printf '%s' "$out" | "$JQ" '.counts.admitted')
[ "$admitted_n" -eq 8 ] || fail "AC1: expected 8 admitted, got $admitted_n: $out"
for i in 1 2 3 4 5 6 7 8; do
  printf '%s' "$out" | "$JQ" -e --arg s "rext$i" '.admitted[] | select(.slug == $s)' >/dev/null \
    || fail "AC1: rext$i missing from admitted[]"
done
[ "$FAILED" -eq 0 ] && pass "AC1"

# ============================================================================
echo "== AC2: same fixture, BUILD_DISTINCT_TARGETS=1 -> 1 admitted, 7 same-target skips =="
FAKE_BURST_READY=true FAKE_BURST_WIDTH=8
out=$(BUILD_DISTINCT_TARGETS=1 BUILD_MAX_BRANCHES=30 run_select_tick --format json)
admitted_n=$(printf '%s' "$out" | "$JQ" '.counts.admitted')
[ "$admitted_n" -eq 1 ] || fail "AC2: expected 1 admitted, got $admitted_n: $out"
same_target_n=$(printf '%s' "$out" | "$JQ" '[.skipped[] | select(.reason == "same-target")] | length')
[ "$same_target_n" -eq 7 ] || fail "AC2: expected 7 same-target skips, got $same_target_n: $out"
[ "$FAILED" -eq 0 ] && pass "AC2"
FAKE_BURST_READY=false

# ============================================================================
echo "== AC3: a Depends-on naming a PRD still in build-queue/ is skipped waiting-on =="
clear_queue
write_prd waited shell /tmp/select-tick-waited-repo
write_prd waiter shell /tmp/select-tick-waiter-repo PRD-waited.md
out=$(run_select_tick --format json)
reason=$(printf '%s' "$out" | "$JQ" -r '.skipped[] | select(.slug == "waiter") | .reason')
detail=$(printf '%s' "$out" | "$JQ" -r '.skipped[] | select(.slug == "waiter") | .detail')
[ "$reason" = "waiting-on" ] || fail "AC3: expected waiter skipped waiting-on, got reason=$reason: $out"
[ "$detail" = "waited" ] || fail "AC3: expected detail to name 'waited', got: $detail"
printf '%s' "$out" | "$JQ" -e '.admitted[] | select(.slug == "waited")' >/dev/null \
  || fail "AC3: expected 'waited' itself admitted (nothing blocks it)"
[ "$FAILED" -eq 0 ] && pass "AC3"

# ============================================================================
echo "== AC4: 35 admissible PRDs (distinct build_into each), BUILD_MAX_BRANCHES=30 =="
clear_queue
for i in $(seq -w 1 35); do
  write_prd "cap$i" shell "/tmp/select-tick-cap-repo-$i"
done
out=$(BUILD_MAX_BRANCHES=30 run_select_tick --format json)
admitted_n=$(printf '%s' "$out" | "$JQ" '.counts.admitted')
cap_skips=$(printf '%s' "$out" | "$JQ" '[.skipped[] | select(.reason == "cap")] | length')
[ "$admitted_n" -eq 30 ] || fail "AC4: expected exactly 30 admitted, got $admitted_n"
[ "$cap_skips" -eq 5 ] || fail "AC4: expected exactly 5 cap-skips, got $cap_skips"
[ "$FAILED" -eq 0 ] && pass "AC4"

# ============================================================================
# PRD-build-select-tick-run-pin fixtures (requirement 8 / that PRD's own
# ACs 1-4). test_prefix `pin` also has dedicated tests/pin_ac*.sh cases for
# the tick-run.sh / SKILL.md legs (that PRD's ACs 5-7); these four exercise
# select-tick.sh's own --pin behavior directly, reusing this file's
# write_prd/run_select_tick/clear_queue fixtures per requirement 8.
echo "== run-pin AC1: 8 candidates cap 5, --pin low1,low2 admits them first in order =="
clear_queue
for i in 1 2 3 4 5 6; do
  write_prd "prio$i" shell "/tmp/select-tick-pin-repo-$i"
done
write_prd low1 shell /tmp/select-tick-pin-repo-low1
write_prd low2 shell /tmp/select-tick-pin-repo-low2
out=$(BUILD_MAX_BRANCHES=5 run_select_tick --format json --pin low1,low2)
first_two=$(printf '%s' "$out" | "$JQ" -r '.admitted[0].slug + "," + .admitted[1].slug')
[ "$first_two" = "low1,low2" ] || fail "run-pin AC1: expected low1,low2 admitted first, got: $first_two"
low1_pinned=$(printf '%s' "$out" | "$JQ" -r '.admitted[] | select(.slug=="low1") | .pinned')
low2_pinned=$(printf '%s' "$out" | "$JQ" -r '.admitted[] | select(.slug=="low2") | .pinned')
[ "$low1_pinned" = "true" ] && [ "$low2_pinned" = "true" ] || fail "run-pin AC1: expected pinned:true on low1/low2"
pinned_arr=$(printf '%s' "$out" | "$JQ" -c '.pinned')
[ "$pinned_arr" = '["low1","low2"]' ] || fail "run-pin AC1: expected top-level pinned==[low1,low2], got $pinned_arr"
admitted_n=$(printf '%s' "$out" | "$JQ" '.counts.admitted')
[ "$admitted_n" -eq 5 ] || fail "run-pin AC1: expected 5 admitted (cap), got $admitted_n"
[ "$FAILED" -eq 0 ] && pass "run-pin AC1"

# ============================================================================
echo "== run-pin AC2: cap 2, --pin a,b,c -> a,b admitted, c pin-over-cap =="
clear_queue
write_prd a shell /tmp/select-tick-pin-repo-a
write_prd b shell /tmp/select-tick-pin-repo-b
write_prd c shell /tmp/select-tick-pin-repo-c
: > "$JOURNAL"
out=$(BUILD_MAX_BRANCHES=2 run_select_tick --format json --pin a,b,c)
admitted_slugs=$(printf '%s' "$out" | "$JQ" -c '[.admitted[].slug]')
[ "$admitted_slugs" = '["a","b"]' ] || fail "run-pin AC2: expected [a,b] admitted, got $admitted_slugs"
c_entry=$(printf '%s' "$out" | "$JQ" -c '.skipped[] | select(.slug=="c")')
printf '%s' "$c_entry" | "$JQ" -e '.pinned == true' >/dev/null || fail "run-pin AC2: expected c skipped with pinned:true, got $c_entry"
grep -qE 'select-tick  pin-over-cap  \(slug=c cap=2\)' "$JOURNAL" \
  || fail "run-pin AC2: journal missing pin-over-cap line: $(cat "$JOURNAL")"
[ "$FAILED" -eq 0 ] && pass "run-pin AC2"

# ============================================================================
echo "== run-pin AC3: --pin ghost (no such PRD) -> pin-unknown journaled, others proceed =="
clear_queue
write_prd normalcand shell /tmp/select-tick-pin-repo-normal
: > "$JOURNAL"
out=$(run_select_tick --format json --pin ghost)
rc=$?
[ "$rc" -eq 0 ] || fail "run-pin AC3: expected exit 0, got $rc"
grep -qE 'select-tick  pin-unknown  \(slug=ghost\)' "$JOURNAL" \
  || fail "run-pin AC3: journal missing pin-unknown line: $(cat "$JOURNAL")"
printf '%s' "$out" | "$JQ" -e '.admitted[] | select(.slug=="normalcand")' >/dev/null \
  || fail "run-pin AC3: expected normalcand admitted normally"
[ "$FAILED" -eq 0 ] && pass "run-pin AC3"

# ============================================================================
echo "== run-pin AC4: pinned slug with unmet Depends-on -> pin-refused cause=depends-on-unmet =="
clear_queue
write_prd waited2 shell /tmp/select-tick-pin-waited-repo
write_prd waiter2 shell /tmp/select-tick-pin-waiter-repo PRD-waited2.md
: > "$JOURNAL"
out=$(run_select_tick --format json --pin waiter2)
skip_entry=$(printf '%s' "$out" | "$JQ" -c '.skipped[] | select(.slug=="waiter2")')
printf '%s' "$skip_entry" | "$JQ" -e '.pinned == true' >/dev/null \
  || fail "run-pin AC4: expected waiter2 skipped with pinned:true, got $skip_entry"
grep -qE 'select-tick  pin-refused  \(slug=waiter2 cause=depends-on-unmet\)' "$JOURNAL" \
  || fail "run-pin AC4: journal missing pin-refused depends-on-unmet line: $(cat "$JOURNAL")"
explain_out=$(run_select_tick --explain waiter2 --pin waiter2 2>&1)
echo "$explain_out" | grep -q '^pinned: yes$' || fail "run-pin AC4: --explain missing 'pinned: yes': $explain_out"
echo "$explain_out" | grep -q '^pinned-cause: depends-on-unmet$' || fail "run-pin AC4: --explain missing pinned-cause: $explain_out"
[ "$FAILED" -eq 0 ] && pass "run-pin AC4"

# ============================================================================
echo "== AC6: exactly one select-tick journal line per run + schema-valid JSON =="
clear_queue
write_prd solo shell /tmp/select-tick-solo-repo
: > "$JOURNAL"
out=$(run_select_tick --format json)
n=$(grep -c '  select-tick  ' "$JOURNAL")
[ "$n" -eq 1 ] || fail "AC6: expected exactly 1 select-tick journal line, got $n"
if command -v python3 >/dev/null 2>&1 && python3 -c "import jsonschema" 2>/dev/null; then
  printf '%s' "$out" > "$ROOT/last-output.json"
  python3 - "$ROOT/last-output.json" "$SCHEMA" <<'PYEOF' || fail "AC6: schema validation failed"
import json, sys
import jsonschema
doc = json.load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))
jsonschema.validate(doc, schema)
PYEOF
else
  echo "AC6: jsonschema unavailable, skipping schema validation leg" >&2
fi
[ "$FAILED" -eq 0 ] && pass "AC6"

# ============================================================================
echo "== AC7: own-claim continuation admitted first, exempt from same-target tally =="
clear_queue
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "# PRD: cont1"
  echo
  echo "- Status: building"
  echo "- Lane: contlane $NOW_TS"
  echo "- build_target: shell"
  echo "- build_into: /tmp/select-tick-cont-repo"
  echo "- Vision: visions/fixture.md"
  echo
  echo "## Acceptance criteria"
  echo
  echo "1. P0 — Given a fixture, When select-tick runs, Then it is admitted or skipped deterministically."
} > "$ROOT/build-queue/PRD-cont1.md"
write_prd newcand shell /tmp/select-tick-cont-repo
out=$(BUILD_SAME_TARGET_CAP=1 run_select_tick --lane contlane --format json)
first_slug=$(printf '%s' "$out" | "$JQ" -r '.admitted[0].slug')
[ "$first_slug" = "cont1" ] || fail "AC7: expected cont1 admitted first, got: $first_slug"
cont1_flag=$(printf '%s' "$out" | "$JQ" -r '.admitted[] | select(.slug=="cont1") | .continuation')
[ "$cont1_flag" = "true" ] || fail "AC7: expected cont1.continuation == true, got $cont1_flag"
printf '%s' "$out" | "$JQ" -e '.admitted[] | select(.slug=="newcand")' >/dev/null \
  || fail "AC7: expected newcand admitted (continuation must not count against sub-cap=1)"
[ "$FAILED" -eq 0 ] && pass "AC7"

# ============================================================================
echo "== AC10: --dry-run is byte-identical to a real run's JSON and writes no journal line =="
clear_queue
write_prd dryrun shell /tmp/select-tick-dryrun-repo
: > "$JOURNAL"
real_out=$(run_select_tick --format json)
n_after_real=$(grep -c '  select-tick  ' "$JOURNAL")
[ "$n_after_real" -eq 1 ] || fail "AC10: expected the real run to journal 1 line, got $n_after_real"
dry_out=$(run_select_tick --format json --dry-run)
n_after_dry=$(grep -c '  select-tick  ' "$JOURNAL")
[ "$n_after_dry" -eq 1 ] || fail "AC10: --dry-run must not add a journal line, count now $n_after_dry"
[ "$real_out" = "$dry_out" ] || fail "AC10: --dry-run JSON differs from a real run's JSON"
[ "$FAILED" -eq 0 ] && pass "AC10"

# ============================================================================
echo "== AC12's own requirement: a guard exit-1 (cargo-bound) is a skip, never an admission =="
clear_queue
write_prd rustonly rust-extend /tmp/select-tick-rustonly-repo
out=$(run_select_tick --lane carbon --format json)
printf '%s' "$out" | "$JQ" -e '.admitted[] | select(.slug=="rustonly")' >/dev/null \
  && fail "AC12: rustonly (rust-extend on cargo-free lane carbon) must never be admitted"
reason=$(printf '%s' "$out" | "$JQ" -r '.skipped[] | select(.slug=="rustonly") | .reason')
[ "$reason" = "cargo-bound" ] || fail "AC12: expected reason=cargo-bound, got: $reason"
[ "$FAILED" -eq 0 ] && pass "AC12 failure-path leg"

# ============================================================================
echo "== AC9 smoke: --explain on an admitted slug names the guard's own ok line =="
clear_queue
write_prd explained shell /tmp/select-tick-explained-repo
explain_out=$(run_select_tick --explain explained 2>&1)
echo "$explain_out" | grep -q '^explain: explained' || fail "AC9 smoke: missing explain header"
echo "$explain_out" | grep -q 'result: admitted' || fail "AC9 smoke: expected result: admitted"
[ "$FAILED" -eq 0 ] && pass "AC9 smoke"

# ============================================================================
if [ "$FAILED" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
fi
echo "SOME FAILURES" >&2
exit 1
