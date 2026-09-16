#!/usr/bin/env bash
# decisions-selftest.sh — offline assertions for PRD-build-open-decision-
# escalation's acceptance criteria. tests/decisions_ac*.sh are thin
# per-AC wrappers that `grep -qF` for specific "ok  <label>" lines this
# script prints (same pattern as repo-health-selftest.sh).
#
# Every sandbox is fully isolated (own BUILD_STATE_DIR / BUILD_MANIFEST /
# BUILD_JOURNAL_ROOT) — nothing here ever touches real state or the real
# journal.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
DECISIONS="$SKILL_DIR/scripts/decisions.sh"
BANNER="$SKILL_DIR/scripts/decisions-banner.sh"

pass=0
fail=0
ok() { printf 'ok  %s\n' "$1"; pass=$((pass + 1)); }
notok() { printf 'not ok  %s -- %s\n' "$1" "$2" >&2; fail=$((fail + 1)); }

# new_sandbox -> prints the sandbox root; sets up state/ + a bare manifest
# with slugs a/b/c, isolated from real $HOME state.
new_sandbox() {
  local sbx; sbx="$(mktemp -d "${BUILD_TEST_ROOT:-/tmp}/decisions-selftest.XXXXXX")"
  mkdir -p "$sbx/state" "$sbx/journal"
  echo '{"prds":{"a":{"slug":"a"},"b":{"slug":"b"},"c":{"slug":"c"}}}' > "$sbx/state/manifest.json"
  printf '%s' "$sbx"
}

sbx_env() {  # $1 = sandbox root -> prints export lines to eval
  local sbx="$1"
  printf 'export BUILD_STATE_DIR=%q BUILD_MANIFEST=%q BUILD_JOURNAL_ROOT=%q\n' \
    "$sbx/state" "$sbx/state/manifest.json" "$sbx/journal"
}

ac1() {
  local sbx; sbx="$(new_sandbox)"
  eval "$(sbx_env "$sbx")"
  local id1 id2
  id1="$("$DECISIONS" open "cold-build-time baseline 1063 s vs 600 s" --owner joe --repo mcphost --blocks a,b,c)"
  id2="$("$DECISIONS" open "cold-build-time baseline 1063 s vs 600 s" --owner joe --repo mcphost --blocks a,b,c)"
  local rows; rows="$(wc -l < "$sbx/state/decisions.jsonl")"
  if [ "$id1" = "$id2" ] && [ -n "$id1" ] && [ "$rows" -eq 1 ]; then
    ok "AC1: open twice -> same id, one row, exit 0"
  else
    notok "AC1: open twice -> same id, one row, exit 0" "id1=$id1 id2=$id2 rows=$rows"
  fi
  rm -rf "$sbx"
}

ac2() {
  local sbx; sbx="$(new_sandbox)"
  eval "$(sbx_env "$sbx")"
  local id; id="$("$DECISIONS" open "50h old question" --owner joe)"
  python3 -c "
import json, datetime
p = '$sbx/state/decisions.jsonl'
row = json.loads(open(p).read().splitlines()[0])
now = datetime.datetime.now(datetime.timezone.utc)
row['opened_ts'] = (now - datetime.timedelta(hours=50)).strftime('%Y-%m-%dT%H:%M:%SZ')
row['due'] = (now - datetime.timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ')
open(p, 'w').write(json.dumps(row) + '\n')
"
  local out; out="$("$DECISIONS" list)"
  if printf '%s' "$out" | grep -qF "$id" && printf '%s' "$out" | grep -q 'age_h=50' && printf '%s' "$out" | grep -q OVERDUE; then
    ok "AC2: list shows age_h=50 and OVERDUE for a row 50h past due"
  else
    notok "AC2: list shows age_h=50 and OVERDUE for a row 50h past due" "$out"
  fi
  rm -rf "$sbx"
}

ac3() {
  local sbx; sbx="$(new_sandbox)"
  eval "$(sbx_env "$sbx")"
  local id; id="$("$DECISIONS" open "three blocked slugs" --owner joe --blocks a,b,c)"
  "$DECISIONS" close "$id" "baseline at 1200 s" >/dev/null
  local slug ok_all=1
  for slug in a b c; do
    local last; last="$(python3 -c "
import json
e = json.load(open('$sbx/state/manifest.json'))['prds']['$slug']
il = e.get('iter_log') or []
print(il[-1] if il else '')
")"
    [ "$last" = "decision $id closed: baseline at 1200 s" ] || ok_all=0
  done
  local journal_hits; journal_hits="$(grep -c "decision  closed  (id=$id" "$sbx/journal/$(date -u +%F).md" 2>/dev/null || echo 0)"
  local open_after; open_after="$("$DECISIONS" list)"
  if [ "$ok_all" = "1" ] && [ "$journal_hits" -eq 3 ] && [ -z "$open_after" ]; then
    ok "AC3: close appends decision line to each blocked slug's iter_log, 3 journal lines, list shows no open rows"
  else
    notok "AC3: close appends decision line to each blocked slug's iter_log, 3 journal lines, list shows no open rows" "ok_all=$ok_all journal_hits=$journal_hits open_after=[$open_after]"
  fi
  rm -rf "$sbx"
}

ac4() {
  local sbx; sbx="$(new_sandbox)"
  eval "$(sbx_env "$sbx")"
  "$DECISIONS" open "decision one" --owner joe >/dev/null
  "$DECISIONS" open "decision two" --owner joe >/dev/null
  local stub="$sbx/stub.log"; : > "$stub"
  NOTIFY_CMD="cat >> $stub" "$DECISIONS" nudge
  NOTIFY_CMD="cat >> $stub" "$DECISIONS" nudge
  NOTIFY_CMD="cat >> $stub" "$DECISIONS" nudge
  local stub_lines; stub_lines="$(wc -l < "$stub")"
  local banner_lines; banner_lines="$(grep -c decision "$sbx/state/alerts.banner" 2>/dev/null || echo 0)"
  if [ "$stub_lines" -eq 2 ] && [ "$banner_lines" -eq 2 ]; then
    ok "AC4: nudge x3 in one UTC day delivers exactly 2 lines for 2 open rows"
  else
    notok "AC4: nudge x3 in one UTC day delivers exactly 2 lines for 2 open rows" "stub_lines=$stub_lines banner_lines=$banner_lines"
  fi
  rm -rf "$sbx"
}

ac5() {
  local sbx; sbx="$(new_sandbox)"
  eval "$(sbx_env "$sbx")"
  local id; id="$("$DECISIONS" open "one open row for the banner" --owner joe)"
  local out; out="$("$BANNER")"
  local one_ok=0
  printf '%s' "$out" | grep -qF "$id" && printf '%s' "$out" | grep -qF "one open row for the banner" && one_ok=1

  local sbx2; sbx2="$(new_sandbox)"
  local out2; out2="$(BUILD_STATE_DIR="$sbx2/state" BUILD_MANIFEST="$sbx2/state/manifest.json" BUILD_JOURNAL_ROOT="$sbx2/journal" "$BANNER")"

  if [ "$one_ok" = "1" ] && [ -z "$out2" ]; then
    ok "AC5: SessionStart hook prints id+question with one open row, nothing with zero"
  else
    notok "AC5: SessionStart hook prints id+question with one open row, nothing with zero" "one_ok=$one_ok out2=[$out2]"
  fi
  rm -rf "$sbx" "$sbx2"
}

ac6() {
  local sbx; sbx="$(new_sandbox)"
  eval "$(sbx_env "$sbx")"
  local fixture="$SKILL_DIR/tests/fixtures/decisions/vision-sample.md"
  local out1 out2 n1 n2
  out1="$("$DECISIONS" import-vision "$fixture" 2>&1)"
  n1="$(wc -l < "$sbx/state/decisions.jsonl")"
  out2="$("$DECISIONS" import-vision "$fixture" 2>&1)"
  n2="$(wc -l < "$sbx/state/decisions.jsonl")"
  if [ "$n1" -ge 7 ] && [ "$n1" -eq "$n2" ]; then
    ok "AC6: import-vision opens >=7 rows once, zero more on a second run (n1=$n1 n2=$n2)"
  else
    notok "AC6: import-vision opens >=7 rows once, zero more on a second run" "n1=$n1 n2=$n2 out1=[$out1] out2=[$out2]"
  fi
  rm -rf "$sbx"
}

ac7() {
  local sbx; sbx="$(new_sandbox)"
  local t0 t1 elapsed out
  t0="$(date +%s.%N)"
  out="$(DECISIONS_REMOTE=unreachable-host-does-not-exist-xyz DECISIONS_SSH_TIMEOUT=2 \
    BUILD_STATE_DIR="$sbx/state" BUILD_MANIFEST="$sbx/state/manifest.json" BUILD_JOURNAL_ROOT="$sbx/journal" \
    "$BANNER")"
  t1="$(date +%s.%N)"
  elapsed="$(python3 -c "print($t1 - $t0)")"
  if [ "$out" = "decisions: unreachable-host-does-not-exist-xyz unreachable" ] && python3 -c "exit(0 if $elapsed < 5 else 1)"; then
    ok "AC7: DECISIONS_REMOTE unreachable prints exact message and returns within 5s (${elapsed}s)"
  else
    notok "AC7: DECISIONS_REMOTE unreachable prints exact message and returns within 5s" "out=[$out] elapsed=${elapsed}s"
  fi
  rm -rf "$sbx"
}

case "${1:-all}" in
  ac1) ac1 ;;
  ac2) ac2 ;;
  ac3) ac3 ;;
  ac4) ac4 ;;
  ac5) ac5 ;;
  ac6) ac6 ;;
  ac7) ac7 ;;
  all) ac1; ac2; ac3; ac4; ac5; ac6; ac7 ;;
  *) echo "usage: decisions-selftest.sh [ac1|ac2|ac3|ac4|ac5|ac6|ac7|all]" >&2; exit 2 ;;
esac

total=$((pass + fail))
echo "decisions-selftest: $pass/$total ok, $fail FAIL" >&2
[ "$fail" -eq 0 ]
