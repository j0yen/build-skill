#!/usr/bin/env bash
# gate-red-tick-selftest.sh — PRD-build-gate-red-alarm-invariant AC4-AC7
# (test_prefix: gatered).
#
#   AC4 — a red tick with a stub NOTIFY_CMD: the journal gets a
#     `gate-red green=… red=…` line, the stub's stdin carries the
#     summary line, and state/alerts.banner gains one gate-red line.
#     Covered twice: gate-red-tick.sh's own contract in isolation below,
#     then an AC4-integration case running the REAL select-tick.sh end to
#     end (empty PRD pool — the wiring fires regardless of admitted count)
#     to prove the `gate-red ...` line lands directly after select-tick's
#     own tick-summary line, per select-tick.sh's own tail wiring.
#   AC5 — red drops from >0 to 0: alert-deliver.sh resolve fires (banner
#     gains a `resolved` line), no new alarm delivery call is made.
#   AC6 — three consecutive ticks with the same red-slug set: the third
#     journals `ALARM gate-red-persistent ticks=3 slugs=…` and the
#     NOTIFY_CMD stub's stdin carries `value=3`.
#   AC7 — the red-slug set changes between two same-day ticks (both past
#     the first delivery): notify-gh-issue.sh's real default path (a
#     fake `gh` on $PATH, no NOTIFY_CMD override) posts exactly one
#     `gh issue comment` on the existing issue, never a second
#     `gh issue create`.
#
# All fixture timestamps sit on the REAL current UTC calendar day
# (journal_line's own writes are always real-wall-clock, so keeping the
# fixture's --now anchor on the same day keeps everything in one file and
# avoids any midnight-rollover flakiness in this selftest itself).
#
# Isolated: BUILD_JOURNAL_ROOT/BUILD_STATE_DIR point under a disposable
# tempdir per case; AC7's fake `gh` is prepended onto $PATH only for that
# case's subshell, never touching the real `gh` or j0yen/prds.
#
# Run: bash scripts/gate-red-tick-selftest.sh   (exit 0 = all pass)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GRT="$HERE/gate-red-tick.sh"
[ -x "$GRT" ] || { echo "selftest: $GRT not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "selftest: jq not on \$PATH, cannot run" >&2; exit 2; }

TODAY="$(date -u +%F)"

T="$(mktemp -d "${TMPDIR:-/tmp}/gate-red-tick-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; PASS=$((PASS+1))
  else echo "FAIL $label ($cond)" >&2; FAIL=$((FAIL+1)); fi
}
today_file() { printf '%s/%s.md\n' "$1" "$TODAY"; }

# ============================================================================
# AC4 — first red tick: journal line, stub stdin, banner line.
# ============================================================================
D="$T/ac4"; mkdir -p "$D/journal" "$D/state"
printf '%sT04:00:00Z  gate-then-land  slugA  gate-block attempt=1 blockers=x\n' "$TODAY" > "$(today_file "$D/journal")"
capture="$D/notify.stdin"
: > "$capture"
BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" NOTIFY_CMD="cat >> $capture" \
  "$GRT" --now "${TODAY}T05:00:00Z" --window-h 2 >/dev/null
rc=$?
expect "AC4 exit 0" "[ $rc -eq 0 ]"
jf="$(today_file "$D/journal")"
expect "AC4 journal has gate-red line" "grep -q '  gate-red  green=0 red=1 families=x=1' '$jf'"
expect "AC4 notify stub got the summary line" "grep -q 'GATES(2h): green=0 red=1' '$capture'"
expect "AC4 banner gained a gate-red line" "grep -q 'build-loop gate-red value=1' '$D/state/alerts.banner'"

# ============================================================================
# AC5 — red -> 0 resolves; no new delivery.
# ============================================================================
D="$T/ac5"; mkdir -p "$D/journal" "$D/state"
printf '%sT04:00:00Z  gate-then-land  slugA  gate-block attempt=1 blockers=x\n' "$TODAY" > "$(today_file "$D/journal")"
capture5="$D/notify.stdin"
: > "$capture5"
BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" NOTIFY_CMD="cat >> $capture5" \
  "$GRT" --now "${TODAY}T05:00:00Z" --window-h 2 >/dev/null
: > "$capture5"
# Second tick: window anchored well past the only red line -> red=0 now.
BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" NOTIFY_CMD="cat >> $capture5" \
  "$GRT" --now "${TODAY}T10:00:00Z" --window-h 1 >/dev/null
rc=$?
expect "AC5 exit 0" "[ $rc -eq 0 ]"
expect "AC5 banner gained a resolved line" "grep -q 'build-loop gate-red resolved' '$D/state/alerts.banner'"
expect "AC5 no second delivery to the stub" "[ ! -s '$capture5' ]"

# ============================================================================
# AC6 — three consecutive ticks, same red-slug set -> escalation at streak 3.
# ============================================================================
D="$T/ac6"; mkdir -p "$D/journal" "$D/state"
printf '%sT04:00:00Z  gate-then-land  slugA  gate-block attempt=1 blockers=x\n' "$TODAY" > "$(today_file "$D/journal")"
capture6="$D/notify.stdin"
for _i in 1 2 3; do
  : > "$capture6"
  BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" NOTIFY_CMD="cat >> $capture6" \
    "$GRT" --now "${TODAY}T05:00:00Z" --window-h 2 >/dev/null
done
jf6="$(today_file "$D/journal")"
expect "AC6 journal has ALARM gate-red-persistent ticks=3" "grep -q 'ALARM  gate-red-persistent  ticks=3 slugs=slugA' '$jf6'"
expect "AC6 stub stdin carries value=3" "grep -q 'value=3' '$capture6'"

# ============================================================================
# AC7 — red-slug set changes between two same-day ticks: notify-gh-issue.sh
# posts a COMMENT on the existing issue, not a second create. Real default
# path (no NOTIFY_CMD), a fake `gh` on $PATH.
# ============================================================================
D="$T/ac7"; mkdir -p "$D/journal" "$D/state" "$D/bin" "$D/ghstate"
cat > "$D/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
STATE="__GHSTATE__"
mkdir -p "$STATE"
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi
if [ "$1" = "label" ] && [ "$2" = "create" ]; then exit 0; fi
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  jq_expr=""; shift 2
  while [ "$#" -gt 0 ]; do [ "$1" = "--jq" ] && jq_expr="$2"; shift; done
  wanted="$(printf '%s' "$jq_expr" | sed -n 's/.*title == "\([^"]*\)".*/\1/p')"
  if [ -f "$STATE/issue.json" ]; then
    st="$(jq -r '.[0].title' "$STATE/issue.json" 2>/dev/null)"
    su="$(jq -r '.[0].url' "$STATE/issue.json" 2>/dev/null)"
    [ "$st" = "$wanted" ] && printf '%s\n' "$su"
  fi
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  shift 2; title=""
  while [ "$#" -gt 0 ]; do [ "$1" = "--title" ] && title="$2"; shift; done
  url="https://github.com/fake/repo/issues/999"
  printf '[{"title":%s,"url":%s}]\n' "$(jq -Rn --arg t "$title" '$t')" "$(jq -Rn --arg u "$url" '$u')" > "$STATE/issue.json"
  echo "create" >> "$STATE/calls.log"
  echo "$url"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
  url="$3"; shift 3; bodyfile=""
  while [ "$#" -gt 0 ]; do [ "$1" = "--body-file" ] && bodyfile="$2"; shift; done
  echo "comment $url" >> "$STATE/calls.log"
  exit 0
fi
echo "fakegh: unhandled args: $*" >&2
exit 1
FAKEGH
sed -i "s#__GHSTATE__#$D/ghstate#" "$D/bin/gh"
chmod +x "$D/bin/gh"
printf '%sT04:00:00Z  gate-then-land  slugX  gate-block attempt=1 blockers=y\n' "$TODAY" > "$(today_file "$D/journal")"
(
  export PATH="$D/bin:$PATH"
  export BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state"
  unset NOTIFY_CMD
  "$GRT" --now "${TODAY}T05:00:00Z" --window-h 2 >/dev/null 2>&1
  printf '%sT04:30:00Z  gate-then-land  slugZ  gate-block attempt=1 blockers=w\n' "$TODAY" >> "$(today_file "$D/journal")"
  "$GRT" --now "${TODAY}T05:00:00Z" --window-h 2 >/dev/null 2>&1
)
expect "AC7 exactly one create call" "[ \"\$(grep -c '^create$' '$D/ghstate/calls.log' 2>/dev/null)\" = 1 ]"
expect "AC7 exactly one comment call" "[ \"\$(grep -c '^comment ' '$D/ghstate/calls.log' 2>/dev/null)\" = 1 ]"
expect "AC7 comment targets the existing issue" "grep -q 'comment https://github.com/fake/repo/issues/999' '$D/ghstate/calls.log'"

# ============================================================================
# AC4-integration — the REAL select-tick.sh, end to end, with an empty PRD
# pool (the gate-red wiring fires at the tick's tail regardless of admitted
# count — this is a tick-level invariant, not conditioned on selection).
# select-tick.sh's own fixture line must sit within the real 3h default
# window (no --now override reaches select-tick.sh itself in production),
# so it's timestamped 30 minutes before "now" rather than a fixed hour.
# ============================================================================
SELECT_TICK="$HERE/select-tick.sh"
if [ -x "$SELECT_TICK" ]; then
  D="$T/ac4-integration"; mkdir -p "$D/prds/build-queue" "$D/prds/built-prds" "$D/prds/parked" "$D/state" "$D/journal"
  printf '{"prds":{}}\n' > "$D/state/manifest.json"
  jf_int="$(today_file "$D/journal")"
  recent="$(date -u -d '-30 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s  gate-then-land  slugA  gate-block attempt=1 blockers=x\n' "$recent" > "$jf_int"
  capture_int="$D/notify.stdin"
  : > "$capture_int"
  BUILD_STATE_DIR="$D/state" SELECT_TICK_JOURNAL="$jf_int" BUILD_JOURNAL_ROOT="$D/journal" \
    NOTIFY_CMD="cat >> $capture_int" \
    "$SELECT_TICK" --prd-dir "$D/prds" --lane gatered-selftest --format json >/dev/null
  rc=$?
  expect "AC4-integration select-tick.sh exit 0" "[ $rc -eq 0 ]"
  # exactly the select-tick line immediately followed by the gate-red line.
  expect "AC4-integration gate-red line directly follows select-tick line" \
    "[ \"\$(grep -n 'select-tick  admitted=' '$jf_int' | head -1 | cut -d: -f1)\" -eq \$(( \$(grep -n '  gate-red  green=' '$jf_int' | head -1 | cut -d: -f1) - 1 )) ]"
  expect "AC4-integration red=1 in the journaled line" "grep -q '  gate-red  green=0 red=1 families=x=1' '$jf_int'"
  expect "AC4-integration stub got the summary line" "grep -q 'GATES(3h): green=0 red=1' '$capture_int'"
  expect "AC4-integration banner gained a gate-red line" "grep -q 'build-loop gate-red value=1' '$D/state/alerts.banner'"
else
  echo "FAIL AC4-integration: select-tick.sh not found at $SELECT_TICK" >&2
  FAIL=$((FAIL + 1))
fi

echo "gate-red-tick-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
