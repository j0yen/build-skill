#!/usr/bin/env bash
# gate-red-summary-selftest.sh — PRD-build-gate-red-alarm-invariant AC1-AC3
# (test_prefix: gatered).
#
#   AC1 — a small hand-built fixture: 2 slugs gate-blocked (blockers a,b
#     and a), 1 slug archived, and one of the blocked slugs later landed.
#     Expect green=2 red=1, families "a x2 b x1", red_slugs names only
#     the still-red slug.
#   AC2 — the REAL 2026-09-16 journal, frozen at the 14:35:09Z line the
#     stopgap (~/.local/bin/gate-red-alarm.sh) actually produced that
#     issued j0yen/prds#9 (see tests/fixtures/gatered/README.md), copied
#     verbatim as tests/fixtures/gatered/2026-09-16-frozen-1435.md.
#     R1 run with GATE_RED_WINDOW_H=3 anchored at that same instant must
#     print red=5, name the five mcphost slugs, and rank hermetic-build
#     as the top family — reproducing the stopgap's own aggregate (the
#     stopgap's red_slugs output was itself bug-shaped at delivery time;
#     this selftest asserts R1's CORRECT classification against the same
#     real data, not the stopgap's buggy issue body).
#   AC3 — a journal line with no leading ISO timestamp (a continuation
#     line, `  ACTION: ...`) is skipped, counted in the JSON twin's
#     `parse_skipped`, and the run still exits 0.
#
# Isolated: BUILD_JOURNAL_ROOT and BUILD_STATE_DIR point under a
# disposable tempdir per case — this selftest never reads or writes the
# real production journal or state/ (scripts/lib/journal.sh's own
# production-write tripwire would refuse fixture-shaped text there
# anyway).
#
# Run: bash scripts/gate-red-summary-selftest.sh   (exit 0 = all pass)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
GRS="$HERE/gate-red-summary.sh"
FIXTURE="$SKILL_DIR/tests/fixtures/gatered/2026-09-16-frozen-1435.md"
[ -x "$GRS" ] || { echo "selftest: $GRS not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "selftest: jq not on \$PATH, cannot run" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gate-red-summary-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; PASS=$((PASS+1))
  else echo "FAIL $label ($cond)" >&2; FAIL=$((FAIL+1)); fi
}

# ============================================================================
# AC1 — small hand-built fixture, exact-line assertion.
# ============================================================================
D="$T/ac1"; mkdir -p "$D/journal" "$D/state"
cat > "$D/journal/2026-01-01.md" <<'EOF'
2026-01-01T00:00:00Z  gate-then-land  slug1  gate-block attempt=1 blockers=a,b
2026-01-01T00:05:00Z  gate-then-land  slug2  gate-block attempt=1 blockers=a
2026-01-01T00:10:00Z  slug3  archive  archived  (repo=fixture)
2026-01-01T00:15:00Z  gate-then-land  slug1  landed attempt=2 version=1.2.3 sha=deadbeef
EOF
out1="$(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" "$GRS" --now 2026-01-01T01:00:00Z --window-h 2)"
rc1=$?
expect "AC1 exit 0" "[ $rc1 -eq 0 ]"
# PRD-build-gate-infra-outcome R6: the summary line gained `incomplete=<n>`
# (right after red=) and an `incomplete_infra:` family field (right after
# `blockers:`) — both `0`/`none` here since this fixture has no
# gate-incomplete lines. Format only, not this PRD's own behavior under
# test (see gate-infra-selftest.sh for that).
expect "AC1 exact line" "[ \"\$out1\" = 'GATES(2h): green=2 red=1 incomplete=0 blockers: a x2 b x1 incomplete_infra: none oldest-red=2026-01-01T00:00:00Z red_slugs: slug2' ]"
json1="$(cat "$D/state/gate-red.json")"
expect "AC1 json green=2" "[ \"\$(printf '%s' \"\$json1\" | jq -r .green)\" = 2 ]"
expect "AC1 json red=1" "[ \"\$(printf '%s' \"\$json1\" | jq -r .red)\" = 1 ]"
expect "AC1 json red_slugs=[slug2]" "[ \"\$(printf '%s' \"\$json1\" | jq -c .red_slugs)\" = '[\"slug2\"]' ]"

# ============================================================================
# AC2 — the real 2026-09-16 journal, frozen at the stopgap's own
# 14:35:09Z line, copied verbatim as a fixture.
# ============================================================================
D="$T/ac2"; mkdir -p "$D/journal" "$D/state"
if [ -r "$FIXTURE" ]; then
  cp "$FIXTURE" "$D/journal/2026-09-16.md"
  out2="$(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" "$GRS" --now 2026-09-16T14:35:09Z --window-h 3)"
  rc2=$?
  expect "AC2 exit 0" "[ $rc2 -eq 0 ]"
  expect "AC2 red=5" "[[ \"\$out2\" == *'red=5'* ]]"
  expect "AC2 top family hermetic-build" "[[ \"\$out2\" == *'blockers: hermetic-build x9'* ]]"
  for s in mcphost-agent-consent mcphost-agent-wake mcphost-gate-debt-4f1112d mcphost-stdlib-pseudo-modules mcphost-tenant-self-offboard; do
    expect "AC2 names $s" "[[ \"\$out2\" == *'$s'* ]]"
  done
  json2="$(cat "$D/state/gate-red.json")"
  expect "AC2 json red_slugs count=5" "[ \"\$(printf '%s' \"\$json2\" | jq '.red_slugs | length')\" = 5 ]"
else
  echo "FAIL AC2 fixture missing: $FIXTURE" >&2
  FAIL=$((FAIL + 1))
fi

# ============================================================================
# AC3 — a line with no leading timestamp is skipped, counted, non-fatal.
# ============================================================================
D="$T/ac3"; mkdir -p "$D/journal" "$D/state"
cat > "$D/journal/2026-01-02.md" <<'EOF'
2026-01-02T00:00:00Z  gate-then-land  slugA  gate-block attempt=1 blockers=x
  ACTION: post-land-gate-recheck outcome=gate-blocked next=gate-red lane=redbaron
2026-01-02T00:05:00Z  gate-then-land  slugB  landed attempt=1 version=1.0.0 sha=cafebabe
EOF
out3="$(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" "$GRS" --now 2026-01-02T01:00:00Z --window-h 2)"
rc3=$?
expect "AC3 exit 0" "[ $rc3 -eq 0 ]"
json3="$(cat "$D/state/gate-red.json")"
expect "AC3 parse_skipped=1" "[ \"\$(printf '%s' \"\$json3\" | jq -r .parse_skipped)\" = 1 ]"
expect "AC3 still counts slugA red, slugB green" "[[ \"\$out3\" == *'green=1 red=1'* ]]"

# ============================================================================
# AC4 — PRD-build-gate-red-retraction: a RED_SLUG whose manifest.json
# status is archived is retracted (counted green, red_slugs empties,
# retracted_slugs names it, summary line gains ` retracted: <slug>`).
# Control case: same fixture, status queued instead -> the red stands.
# ============================================================================
D="$T/ac4"; mkdir -p "$D/journal" "$D/state"
cat > "$D/journal/2026-01-03.md" <<'EOF'
2026-01-03T00:00:00Z  gate-then-land  slugR  gate-block attempt=1 blockers=x
EOF
python3 -c "
import json
json.dump({'prds': {'slugR': {'slug': 'slugR', 'status': 'archived'}}}, open('$D/state/manifest.json', 'w'))
"
out4="$(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" "$GRS" --now 2026-01-03T01:00:00Z --window-h 2)"
rc4=$?
expect "AC4 exit 0" "[ $rc4 -eq 0 ]"
expect "AC4 red=0" "[[ \"\$out4\" == *'red=0'* ]]"
expect "AC4 no red_slugs" "[[ \"\$out4\" == *'red_slugs: '* ]]"
expect "AC4 summary names retracted slug" "[[ \"\$out4\" == *'retracted: slugR'* ]]"
json4="$(cat "$D/state/gate-red.json")"
expect "AC4 json red_slugs=[]" "[ \"\$(printf '%s' \"\$json4\" | jq -c .red_slugs)\" = '[]' ]"
expect "AC4 json retracted_slugs=[slugR]" "[ \"\$(printf '%s' \"\$json4\" | jq -c .retracted_slugs)\" = '[\"slugR\"]' ]"
expect "AC4 json oldest_red=none" "[ \"\$(printf '%s' \"\$json4\" | jq -r .oldest_red)\" = none ]"

# Control: same fixture, slugR still queued -> the red stands, no retraction.
D="$T/ac4-control"; mkdir -p "$D/journal" "$D/state"
cat > "$D/journal/2026-01-03.md" <<'EOF'
2026-01-03T00:00:00Z  gate-then-land  slugR  gate-block attempt=1 blockers=x
EOF
python3 -c "
import json
json.dump({'prds': {'slugR': {'slug': 'slugR', 'status': 'queued'}}}, open('$D/state/manifest.json', 'w'))
"
out4c="$(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" "$GRS" --now 2026-01-03T01:00:00Z --window-h 2)"
expect "AC4 control red=1 (queued, not retracted)" "[[ \"\$out4c\" == *'red=1'* ]]"
expect "AC4 control names slugR still red" "[[ \"\$out4c\" == *'red_slugs: slugR'* ]]"
expect "AC4 control no retracted suffix" "[[ \"\$out4c\" != *'retracted:'* ]]"
json4c="$(cat "$D/state/gate-red.json")"
expect "AC4 control json retracted_slugs=[]" "[ \"\$(printf '%s' \"\$json4c\" | jq -c .retracted_slugs)\" = '[]' ]"

# ============================================================================
# R9 — gate-status.sh --red prints the JSON twin verbatim.
# ============================================================================
GS="$SKILL_DIR/scripts/gate-status.sh"
if [ -x "$GS" ]; then
  D="$T/r9"; mkdir -p "$D/state"
  BUILD_STATE_DIR="$D/state" GATE_RED_JSON_FILE="$D/state/gate-red.json" "$GRS" --now 2026-01-01T01:00:00Z --window-h 2 >/dev/null 2>&1
  # (empty journal -> green=0 red=0, just proving the file round-trips)
  echo '{"ts":"2026-01-01T00:00:00Z","red":2}' > "$D/state/gate-red.json"
  out_r9="$(BUILD_STATE_DIR="$D/state" "$GS" --red)"
  expect "R9 gate-status --red prints the JSON twin" "[ \"\$out_r9\" = '{\"ts\":\"2026-01-01T00:00:00Z\",\"red\":2}' ]"
  out_r9_missing="$(BUILD_STATE_DIR="$T/r9-missing" "$GS" --red)"
  expect "R9 gate-status --red prints {} when no file exists" "[ \"\$out_r9_missing\" = '{}' ]"
else
  echo "FAIL R9: gate-status.sh not found at $GS" >&2
  FAIL=$((FAIL + 1))
fi

echo "gate-red-summary-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
