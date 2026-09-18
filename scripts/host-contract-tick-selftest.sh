#!/usr/bin/env bash
# host-contract-tick-selftest.sh — PRD-build-host-contract AC3 and the
# lane-health half of AC6.
#
#   AC3 — a critical host-contract drift on lane=redbaron: select-tick.sh
#     admits nothing, journals `dispatch  host-drift  <keys>`, and an
#     already-running fixture process is untouched (select-tick.sh never
#     manages running units, so this is really "still true after", not
#     something select-tick.sh has to actively preserve).
#   AC6 (lane-health half) — lane-health.sh's own tick line ends `host=ok`
#     when host-contract.sh check is all-ok, `host=drift:<csv>` otherwise,
#     and its exit code mirrors host-contract.sh check's own.
#
# Both scripts are pointed at a small deterministic fixture double of
# host-contract.sh (via $HOST_CONTRACT_SH) rather than the real one --
# the real script probes the actual host (systemctl/df/fuser/systemd-run)
# which would make this selftest's pass/fail depend on RedBaron's live
# state at run time.
#
# Run: bash scripts/host-contract-tick-selftest.sh   (exit 0 = all pass)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ST="$HERE/select-tick.sh"
LH="$HERE/lane-health.sh"
[ -x "$ST" ] || { echo "selftest: $ST not executable" >&2; exit 2; }
[ -x "$LH" ] || { echo "selftest: $LH not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "selftest: jq not on \$PATH, cannot run" >&2; exit 2; }

# shellcheck source=lib/isolation.sh
source "$HERE/lib/isolation.sh"
selftest_init || { echo "host-contract-tick-selftest: selftest_init failed" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/host-contract-tick-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; PASS=$((PASS+1))
  else echo "FAIL $label ($cond)" >&2; FAIL=$((FAIL+1)); fi
}

FAKE_HC="$T/fake-host-contract.sh"
cat > "$FAKE_HC" <<'FAKEHC'
#!/usr/bin/env bash
if [ "${1:-}" = "check" ]; then
  if [ "${FAKE_HC_MODE:-ok}" = "drift" ]; then
    echo "manager-env:TMPDIR=drift(unset) severity=critical owner=self-heal"
    echo "tmp-usage:/tmp=drift(80%) severity=critical owner=operator"
    echo "path:autobuilder=drift(2-on-PATH) severity=warn owner=operator"
    exit 2
  fi
  echo "manager-env:TMPDIR=ok"
  echo "tmp-usage:/tmp=ok"
  exit 0
fi
exit 0
FAKEHC
chmod +x "$FAKE_HC"

# ============================================================================
# lane-health.sh — ok case.
# ============================================================================
D="$T/lh-ok"; mkdir -p "$D/journal"
out="$(BUILD_JOURNAL_ROOT="$D/journal" HOST_CONTRACT_SH="$FAKE_HC" FAKE_HC_MODE=ok "$LH" --lane testlane)"
rc=$?
expect "lane-health ok exit 0" "[ $rc -eq 0 ]"
expect "lane-health ok line ends host=ok" "grep -qE '  lane-health  testlane  host=ok$' <<<'$out'"
jf="$D/journal/$(date -u +%F).md"
expect "lane-health ok journaled" "grep -qE '  lane-health  testlane  host=ok$' '$jf'"

# ============================================================================
# lane-health.sh — drift case: csv carries every drifted key (both
# severities), exit code mirrors host-contract.sh check's own (2).
# ============================================================================
D="$T/lh-drift"; mkdir -p "$D/journal"
out="$(BUILD_JOURNAL_ROOT="$D/journal" HOST_CONTRACT_SH="$FAKE_HC" FAKE_HC_MODE=drift "$LH" --lane testlane)"
rc=$?
expect "lane-health drift exit 2" "[ $rc -eq 2 ]"
expect "lane-health drift line carries all 3 keys" \
  "grep -qE '  lane-health  testlane  host=drift:manager-env:TMPDIR,tmp-usage:/tmp,path:autobuilder$' <<<'$out'"

# ============================================================================
# AC3 — select-tick.sh, lane=redbaron, critical drift: admits nothing,
# journals dispatch host-drift <keys>, a real running fixture process is
# unaffected.
# ============================================================================
D="$T/ac3"; mkdir -p "$D/build-queue" "$D/visions" "$D/state"
echo "# fixture vision" > "$D/visions/fixture.md"
echo '{"prds":{}}' > "$D/state/manifest.json"
{
  echo "# PRD: hc-tick-fixture"
  echo
  echo "- Status: queued"
  echo "- build_target: shell"
  echo "- Vision: visions/fixture.md"
  echo
  echo "## Acceptance criteria"
  echo
  echo "1. P0 — Given a fixture, When select-tick runs, Then it is admitted or skipped deterministically."
} > "$D/build-queue/PRD-hc-tick-fixture.md"
JOURNAL="$D/journal.md"; : > "$JOURNAL"

sleep 300 &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null; rm -rf "$T"' EXIT

out="$(BUILD_STATE_DIR="$D/state" BUILD_MANIFEST="$D/state/manifest.json" \
  SELECT_TICK_JOURNAL="$JOURNAL" HOST_CONTRACT_SH="$FAKE_HC" FAKE_HC_MODE=drift \
  "$ST" --prd-dir "$D" --lane redbaron --format json)"
rc=$?
expect "AC3 exit 0" "[ $rc -eq 0 ]"
expect "AC3 admitted is empty" "[ \"\$(printf '%s' '$out' | jq '.admitted | length')\" = 0 ]"
expect "AC3 fixture slug is skipped with reason host-drift" \
  "printf '%s' '$out' | jq -e '.skipped[] | select(.slug==\"hc-tick-fixture\") | select(.reason==\"host-drift\")' >/dev/null"
expect "AC3 journal carries dispatch host-drift line" \
  "grep -qE '  dispatch  host-drift  ' '$JOURNAL'"
expect "AC3 fixture process still alive" "kill -0 '$fixture_pid' 2>/dev/null"
kill "$fixture_pid" 2>/dev/null
wait "$fixture_pid" 2>/dev/null

# ============================================================================
# Non-redbaron lane: the same critical drift never refuses admission (the
# probe is redbaron-only per docs/host-contract.md's Migration note).
# ============================================================================
D2="$T/ac3-other-lane"; mkdir -p "$D2/build-queue" "$D2/visions" "$D2/state"
echo "# fixture vision" > "$D2/visions/fixture.md"
echo '{"prds":{}}' > "$D2/state/manifest.json"
cp "$D/build-queue/PRD-hc-tick-fixture.md" "$D2/build-queue/"
JOURNAL2="$D2/journal.md"; : > "$JOURNAL2"
out2="$(BUILD_STATE_DIR="$D2/state" BUILD_MANIFEST="$D2/state/manifest.json" \
  SELECT_TICK_JOURNAL="$JOURNAL2" HOST_CONTRACT_SH="$FAKE_HC" FAKE_HC_MODE=drift \
  "$ST" --prd-dir "$D2" --lane carbon --format json)"
expect "non-redbaron lane still admits despite drift" \
  "printf '%s' '$out2' | jq -e '.admitted | length >= 1' >/dev/null"
expect "non-redbaron lane never journals dispatch host-drift" \
  "! grep -qE '  dispatch  host-drift  ' '$JOURNAL2'"

echo "host-contract-tick-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
